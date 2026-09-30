package indexer

import (
	"regexp"
	"strings"

	sitter "github.com/tree-sitter/go-tree-sitter"
)

// extractElixir walks defmodule trees. In the Elixir grammar everything is a
// (call target: …) node: defmodule, def, alias and a function call all share
// the shape, so extraction dispatches on the target identifier's text.
//
// This replaces upstream grasp's compiler tracer with a syntactic pass: less
// exact (no macro expansion, no default-arity synthesis beyond counting \\),
// but it needs no compile and no Elixir on the machine.
func extractElixir(fp *fileParse, root *sitter.Node, src []byte) {
	ex := &exState{fp: fp, merged: map[string]*record{}}
	for _, c := range namedChildren(root) {
		c := c
		ex.statement(&c, src)
	}
}

type exState struct {
	fp     *fileParse
	merged map[string]*record // id -> record, merging multi-clause functions
	stack  []string           // enclosing defmodule names
	// pendingDecor is the start line of the decoration block sitting above
	// the next definition — attr/slot/@doc/@spec belong to the function they
	// document, so its span absorbs them.
	pendingDecor int
}

// decorations that attach to the definition below them.
var exDecorations = map[string]bool{
	"attr": true, "slot": true,
	"doc": true, "spec": true, "impl": true, "deprecated": true, "tag": true,
}

// elixir special forms and directives that parse as local calls but are not
// function-call edges worth recording.
var exSpecialForms = map[string]bool{
	"def": true, "defp": true, "defmodule": true, "defmacro": true,
	"defmacrop": true, "defguard": true, "defguardp": true, "defstruct": true,
	"defdelegate": true, "defimpl": true, "defprotocol": true,
	"defexception": true, "defoverridable": true,
	"alias": true, "import": true, "require": true, "use": true,
	"if": true, "unless": true, "case": true, "cond": true, "for": true,
	"with": true, "quote": true, "unquote": true, "unquote_splicing": true,
	"receive": true, "try": true, "raise": true, "reraise": true,
	"throw": true, "super": true, "send": true, "self": true,
}

func (ex *exState) statement(n *sitter.Node, src []byte) {
	switch n.Kind() {
	case "call":
		target := n.ChildByFieldName("target")
		if target == nil || target.Kind() != "identifier" {
			ex.pendingDecor = 0
			return
		}
		switch name := target.Utf8Text(src); name {
		case "defmodule":
			ex.pendingDecor = 0
			ex.defmodule(n, src)
		case "def", "defp", "defmacro", "defmacrop":
			ex.definition(n, name, src)
		case "alias":
			ex.pendingDecor = 0
			ex.alias(n, src)
		case "import":
			ex.pendingDecor = 0
			ex.importDirective(n, src)
		default:
			if exDecorations[name] {
				ex.markDecoration(n)
			} else {
				ex.pendingDecor = 0
			}
		}
	case "unary_operator":
		// `@doc "…"` decorates the def below; `@tiles [...]` is a module
		// attribute — a record of its own, so a change to it shows.
		inner := firstNamed(n)
		if inner == nil || inner.Kind() != "call" {
			ex.pendingDecor = 0
			return
		}
		t := inner.ChildByFieldName("target")
		if t == nil || t.Kind() != "identifier" {
			ex.pendingDecor = 0
			return
		}
		name := t.Utf8Text(src)
		if exDecorations[name] {
			ex.markDecoration(n)
			return
		}
		if childOfKind(inner, "arguments") != nil {
			ex.moduleAttr(n, name)
		}
		ex.pendingDecor = 0
	default:
		ex.pendingDecor = 0
	}
}

func (ex *exState) markDecoration(n *sitter.Node) {
	if ex.pendingDecor == 0 {
		ex.pendingDecor = int(n.StartPosition().Row) + 1
	}
}

// moduleAttr records a `@name value` module attribute as a tiny record, so
// the sidebar and the diff cover constants and moduledocs too.
func (ex *exState) moduleAttr(n *sitter.Node, name string) {
	module := ex.currentModule()
	id := module + ".@" + name + "/0"
	if _, dup := ex.merged[id]; dup {
		return
	}
	start := int(n.StartPosition().Row) + 1
	end := int(n.EndPosition().Row) + 1
	rec := ex.fp.newRecord(module, "@"+name, "", 0, nil, "attr", start, end)
	ex.merged[id] = rec
}

func (ex *exState) currentModule() string {
	if len(ex.stack) == 0 {
		return ex.fp.module
	}
	return strings.Join(ex.stack, ".")
}

func (ex *exState) defmodule(n *sitter.Node, src []byte) {
	args := childOfKind(n, "arguments")
	if args == nil {
		return
	}
	nameN := firstNamed(args)
	if nameN == nil || nameN.Kind() != "alias" {
		return
	}
	ex.stack = append(ex.stack, nameN.Utf8Text(src))
	full := strings.Join(ex.stack, ".")
	ex.fp.modules = append(ex.fp.modules, moduleDecl{name: full, line: int(n.StartPosition().Row) + 1})

	if body := childOfKind(n, "do_block"); body != nil {
		for _, c := range namedChildren(body) {
			c := c
			ex.statement(&c, src)
		}
	}
	ex.pendingDecor = 0
	ex.stack = ex.stack[:len(ex.stack)-1]
}

// definition handles one def/defp/defmacro clause. Clauses of the same
// name/arity merge into one record spanning first to last, and the record
// absorbs the decoration block above its first clause — the attr/slot/@doc
// lines belong to the function they document.
func (ex *exState) definition(n *sitter.Node, kind string, src []byte) {
	decor := ex.pendingDecor
	ex.pendingDecor = 0
	args := childOfKind(n, "arguments")
	if args == nil {
		return
	}
	head := firstNamed(args)
	if head == nil {
		return
	}
	// `def foo(a) when guard` wraps the head in a binary_operator.
	if head.Kind() == "binary_operator" {
		head = head.ChildByFieldName("left")
		if head == nil {
			return
		}
	}

	var name string
	arity, defaults := 0, 0
	switch head.Kind() {
	case "call":
		t := head.ChildByFieldName("target")
		if t == nil || t.Kind() != "identifier" {
			return
		}
		name = t.Utf8Text(src)
		if params := childOfKind(head, "arguments"); params != nil {
			for _, p := range namedChildren(params) {
				arity++
				// `opts \\ []` — a default argument makes the lower arity
				// callable too.
				if p.Kind() == "binary_operator" {
					defaults++
				}
			}
		}
	case "identifier":
		name = head.Utf8Text(src) // `def foo, do: …`
	default:
		return
	}

	module := ex.currentModule()
	start := int(n.StartPosition().Row) + 1
	end := int(n.EndPosition().Row) + 1
	id := module + "." + name + "/" + itoa(arity)

	rec := ex.merged[id]
	if rec == nil {
		if decor > 0 && decor < start {
			start = decor
		}
		var arities []int
		for a := arity - defaults; a <= arity; a++ {
			arities = append(arities, a)
		}
		rec = ex.fp.newRecord(module, name, "", arity, arities, kind, start, end)
		ex.merged[id] = rec
	} else {
		if end > rec.fn.Span.EndLine {
			rec.fn.Span.EndLine = end
			rec.fn.Source = ex.fp.sourceLines(rec.fn.Span.StartLine, end)
		}
	}

	// Calls live in the do_block, in a `, do:` keyword body, and in default
	// argument expressions.
	if body := childOfKind(n, "do_block"); body != nil {
		exCalls(body, src, &rec.rawCalls)
	}
	for _, kw := range keywordPairs(args, src) {
		exCalls(kw.value, src, &rec.rawCalls)
	}
	if head.Kind() == "call" {
		if params := childOfKind(head, "arguments"); params != nil {
			for _, p := range namedChildren(params) {
				if p.Kind() == "binary_operator" {
					p := p
					exCalls(&p, src, &rec.rawCalls)
				}
			}
		}
	}
}

// exCalls records remote calls (Mod.fun(…), through aliases), local calls
// (fun(…), minus special forms) and captures (&fun/2, &Mod.fun/2).
func exCalls(n *sitter.Node, src []byte, out *[]rawCall) {
	switch n.Kind() {
	case "call":
		target := n.ChildByFieldName("target")
		if target != nil {
			switch target.Kind() {
			case "identifier":
				name := target.Utf8Text(src)
				if !exSpecialForms[name] {
					c := rawCall{name: name, arity: exArity(n), rng: rangeOf(target)}
					// `render(conn, :show, …)` in a controller reaches the
					// HTML module's :show component by Phoenix convention;
					// carry the view atom so resolution can retarget it.
					if name == "render" || name == "live_render" {
						if args := childOfKind(n, "arguments"); args != nil {
							for _, a := range namedChildren(args) {
								if a.Kind() == "atom" {
									c.hint = strings.TrimPrefix(a.Utf8Text(src), ":")
									break
								}
							}
						}
					}
					*out = append(*out, c)
				}
			case "dot":
				left := target.ChildByFieldName("left")
				right := target.ChildByFieldName("right")
				if left != nil && right != nil && right.Kind() == "identifier" &&
					(left.Kind() == "alias" || leftIsModuleSelf(left, src)) {
					*out = append(*out, rawCall{
						object: left.Utf8Text(src),
						name:   right.Utf8Text(src),
						arity:  exArity(n),
						rng:    rangeOf(target),
					})
				}
			}
		}
	case "unary_operator":
		// `&foo/2` / `&Mod.fun/2`: an exact-arity function reference.
		if c := captureCall(n, src); c != nil {
			*out = append(*out, *c)
		}
	case "sigil":
		// A component tag inside an ~H body is a call site: `<.stats>` calls
		// the local component, `<Layouts.header>` a remote one. The sigil is
		// plain text to the grammar, so tags are found by scanning it.
		if text := n.Utf8Text(src); strings.HasPrefix(text, "~H") {
			heexTags(text, n.StartPosition(), out)
		}
	}
	for i := uint(0); i < n.NamedChildCount(); i++ {
		if c := n.NamedChild(i); c != nil {
			exCalls(c, src, out)
		}
	}
}

var (
	heexLocalTag  = regexp.MustCompile(`<\.([a-z_][a-zA-Z0-9_?!]*)`)
	heexRemoteTag = regexp.MustCompile(`<([A-Z][A-Za-z0-9_.]*)\.([a-z_][a-zA-Z0-9_?!]*)`)
)

// heexTags scans an ~H sigil's text for component tags, mapping each match
// back to its absolute line and column. A function component takes assigns,
// so every tag is a name/1 call.
func heexTags(text string, start sitter.Point, out *[]rawCall) {
	for li, line := range strings.Split(text, "\n") {
		row := int(start.Row) + li + 1
		colBase := 0
		if li == 0 {
			colBase = int(start.Column)
		}
		for _, m := range heexLocalTag.FindAllStringSubmatchIndex(line, -1) {
			*out = append(*out, rawCall{
				name:  line[m[2]:m[3]],
				arity: 1,
				rng:   Range{Start: [2]int{row, colBase + m[0] + 2}, End: [2]int{row, colBase + m[1] + 1}},
			})
		}
		for _, m := range heexRemoteTag.FindAllStringSubmatchIndex(line, -1) {
			*out = append(*out, rawCall{
				object: line[m[2]:m[3]],
				name:   line[m[4]:m[5]],
				arity:  1,
				rng:    Range{Start: [2]int{row, colBase + m[0] + 2}, End: [2]int{row, colBase + m[1] + 1}},
			})
		}
	}
}

func exArity(call *sitter.Node) int {
	args := childOfKind(call, "arguments")
	if args == nil {
		return 0
	}
	return len(namedChildren(args))
}

func captureCall(n *sitter.Node, src []byte) *rawCall {
	op := firstNamed(n)
	if op == nil || op.Kind() != "binary_operator" {
		return nil
	}
	left := op.ChildByFieldName("left")
	right := op.ChildByFieldName("right")
	if left == nil || right == nil || right.Kind() != "integer" {
		return nil
	}
	arity := 0
	for _, ch := range right.Utf8Text(src) {
		arity = arity*10 + int(ch-'0')
	}
	switch left.Kind() {
	case "identifier":
		name := left.Utf8Text(src)
		if exSpecialForms[name] {
			return nil
		}
		return &rawCall{name: name, arity: arity, rng: rangeOf(op)}
	case "dot":
		l := left.ChildByFieldName("left")
		r := left.ChildByFieldName("right")
		if l != nil && r != nil && l.Kind() == "alias" && r.Kind() == "identifier" {
			return &rawCall{object: l.Utf8Text(src), name: r.Utf8Text(src), arity: arity, rng: rangeOf(op)}
		}
	}
	return nil
}

func leftIsModuleSelf(n *sitter.Node, src []byte) bool {
	return n.Kind() == "identifier" && n.Utf8Text(src) == "__MODULE__"
}

func (ex *exState) alias(n *sitter.Node, src []byte) {
	args := childOfKind(n, "arguments")
	if args == nil {
		return
	}
	first := firstNamed(args)
	if first == nil {
		return
	}
	switch first.Kind() {
	case "alias": // alias Foo.Bar [, as: B]
		full := first.Utf8Text(src)
		local := lastSegment(full)
		for _, kw := range keywordPairs(args, src) {
			if kw.key == "as" && kw.value.Kind() == "alias" {
				local = kw.value.Utf8Text(src)
			}
		}
		ex.fp.exAliases[local] = full
	case "dot": // alias Foo.{Bar, Baz}
		left := first.ChildByFieldName("left")
		right := first.ChildByFieldName("right")
		if left == nil || right == nil || left.Kind() != "alias" || right.Kind() != "tuple" {
			return
		}
		prefix := left.Utf8Text(src)
		for _, a := range namedChildren(right) {
			if a.Kind() == "alias" {
				sub := a.Utf8Text(src)
				ex.fp.exAliases[lastSegment(sub)] = prefix + "." + sub
			}
		}
	}
}

func (ex *exState) importDirective(n *sitter.Node, src []byte) {
	args := childOfKind(n, "arguments")
	if args == nil {
		return
	}
	first := firstNamed(args)
	if first == nil || first.Kind() != "alias" {
		return
	}
	imp := exImport{module: first.Utf8Text(src)}
	for _, kw := range keywordPairs(args, src) {
		if kw.key != "only" || kw.value.Kind() != "list" {
			continue
		}
		imp.hasOnly = true
		imp.only = map[string]bool{}
		var walkOnly func(m *sitter.Node)
		walkOnly = func(m *sitter.Node) {
			if m.Kind() == "pair" {
				k := m.ChildByFieldName("key")
				v := m.ChildByFieldName("value")
				if k != nil && v != nil && v.Kind() == "integer" {
					imp.only[strings.TrimSuffix(k.Utf8Text(src), ":")+"/"+v.Utf8Text(src)] = true
				}
				return
			}
			for i := uint(0); i < m.NamedChildCount(); i++ {
				if c := m.NamedChild(i); c != nil {
					walkOnly(c)
				}
			}
		}
		walkOnly(kw.value)
	}
	ex.fp.exImports = append(ex.fp.exImports, imp)
}

// --- small tree helpers ---

type kwPair struct {
	key   string
	value *sitter.Node
}

func keywordPairs(args *sitter.Node, src []byte) []kwPair {
	var out []kwPair
	for _, c := range namedChildren(args) {
		if c.Kind() != "keywords" {
			continue
		}
		for _, p := range namedChildren(&c) {
			if p.Kind() != "pair" {
				continue
			}
			k := p.ChildByFieldName("key")
			v := p.ChildByFieldName("value")
			if k != nil && v != nil {
				out = append(out, kwPair{key: strings.TrimSuffix(k.Utf8Text(src), ":"), value: v})
			}
		}
	}
	return out
}

func childOfKind(n *sitter.Node, kind string) *sitter.Node {
	for i := uint(0); i < n.NamedChildCount(); i++ {
		if c := n.NamedChild(i); c != nil && c.Kind() == kind {
			return c
		}
	}
	return nil
}

func firstNamed(n *sitter.Node) *sitter.Node {
	return n.NamedChild(0)
}

func lastSegment(dotted string) string {
	if i := strings.LastIndexByte(dotted, '.'); i >= 0 {
		return dotted[i+1:]
	}
	return dotted
}
