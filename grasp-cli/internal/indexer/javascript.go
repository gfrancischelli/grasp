package indexer

import (
	"strings"
	"unicode"

	sitter "github.com/tree-sitter/go-tree-sitter"
)

// extractJS walks a JavaScript/TypeScript module's top-level statements:
// function declarations, exported or not, arrow/function values (unwrapping
// React.forwardRef/memo-style wrappers), class methods, and import clauses.
func extractJS(fp *fileParse, root *sitter.Node, src []byte) {
	children := namedChildren(root)
	for i := range children {
		jsStatement(fp, &children[i], src, false, false, nil)
	}
}

func jsStatement(fp *fileParse, stmt *sitter.Node, src []byte, exported, isDefault bool, spanNode *sitter.Node) {
	switch stmt.Kind() {
	case "export_statement":
		hasDefault := false
		for i := uint(0); i < stmt.ChildCount(); i++ {
			if c := stmt.Child(i); c != nil && c.Kind() == "default" {
				hasDefault = true
			}
		}
		if decl := stmt.ChildByFieldName("declaration"); decl != nil {
			jsStatement(fp, decl, src, true, hasDefault, stmt)
			return
		}
		if v := stmt.ChildByFieldName("value"); v != nil {
			if v.Kind() == "identifier" {
				fp.defaultName = v.Utf8Text(src)
			} else if fn := unwrapFunction(v, 3); fn != nil {
				jsRecord(fp, "default", fn, stmt, src, true, true)
			}
		}

	case "function_declaration", "generator_function_declaration":
		name := "default"
		if n := stmt.ChildByFieldName("name"); n != nil {
			name = n.Utf8Text(src)
		}
		jsRecord(fp, name, stmt, spanOr(stmt, spanNode), src, exported, isDefault)

	case "lexical_declaration", "variable_declaration":
		var declarators []sitter.Node
		for _, c := range namedChildren(stmt) {
			if c.Kind() == "variable_declarator" {
				declarators = append(declarators, c)
			}
		}
		for i := range declarators {
			d := &declarators[i]
			nameN := d.ChildByFieldName("name")
			valueN := d.ChildByFieldName("value")
			if nameN == nil || valueN == nil || nameN.Kind() != "identifier" {
				continue
			}
			valueN = unwrapFunction(valueN, 3)
			if valueN == nil {
				continue
			}
			span := d
			if len(declarators) == 1 {
				span = spanOr(stmt, spanNode)
			}
			jsRecord(fp, nameN.Utf8Text(src), valueN, span, src, exported, isDefault)
		}

	case "class_declaration", "abstract_class_declaration":
		nameN := stmt.ChildByFieldName("name")
		body := stmt.ChildByFieldName("body")
		if nameN == nil || body == nil {
			return
		}
		className := nameN.Utf8Text(src)
		for _, m := range namedChildren(body) {
			m := m
			switch m.Kind() {
			case "method_definition":
				if mn := m.ChildByFieldName("name"); mn != nil {
					jsRecord(fp, className+"."+mn.Utf8Text(src), &m, &m, src, exported, false)
				}
			case "field_definition", "public_field_definition":
				prop := m.ChildByFieldName("property")
				value := m.ChildByFieldName("value")
				if prop != nil && value != nil {
					if fn := unwrapFunction(value, 2); fn != nil {
						jsRecord(fp, className+"."+prop.Utf8Text(src), fn, &m, src, exported, false)
					}
				}
			}
		}

	case "import_statement":
		jsImport(fp, stmt, src)
	}
}

// jsRecord creates a Function for a definition. funcNode carries parameters
// and body; spanNode is the full statement the card shows.
func jsRecord(fp *fileParse, localName string, funcNode, spanNode *sitter.Node, src []byte, exported, isDefault bool) {
	if _, dup := fp.byName[localName]; dup {
		return // TS overload signatures, accidental redeclarations: first wins
	}
	kind := "defp"
	if exported {
		kind = "def"
	}
	start := int(spanNode.StartPosition().Row) + 1
	end := int(spanNode.EndPosition().Row) + 1
	rec := fp.newRecord(fp.module, localName, localName, jsParams(funcNode), nil, kind, start, end)
	rec.isDefault = isDefault
	jsCalls(funcNode, src, &rec.rawCalls)
}

func isFunctionKind(kind string) bool {
	switch kind {
	case "arrow_function", "function_expression", "function", "generator_function":
		return true
	}
	return false
}

// unwrapFunction digs a function out of wrapper calls — React.forwardRef(fn),
// memo(() => …), observer(connect(fn)) — up to depth levels of nesting. The
// record keeps the declarator's name; the wrapper is an implementation detail.
func unwrapFunction(n *sitter.Node, depth int) *sitter.Node {
	if isFunctionKind(n.Kind()) {
		return n
	}
	if depth == 0 || n.Kind() != "call_expression" {
		return nil
	}
	args := n.ChildByFieldName("arguments")
	if args == nil {
		return nil
	}
	for i := uint(0); i < args.NamedChildCount(); i++ {
		if c := args.NamedChild(i); c != nil {
			if fn := unwrapFunction(c, depth-1); fn != nil {
				return fn
			}
		}
	}
	return nil
}

func spanOr(node, wrapper *sitter.Node) *sitter.Node {
	if wrapper != nil {
		return wrapper
	}
	return node
}

func jsParams(funcNode *sitter.Node) int {
	if p := funcNode.ChildByFieldName("parameters"); p != nil {
		n := 0
		for _, c := range namedChildren(p) {
			if c.Kind() != "comment" {
				n++
			}
		}
		return n
	}
	// `x => …`: a single bare parameter.
	if funcNode.ChildByFieldName("parameter") != nil {
		return 1
	}
	return 0
}

// jsCalls walks a definition's subtree recording call sites: plain
// `name(...)`, single-level `object.name(...)`, and capitalized JSX tags
// (a component tag is a call site).
func jsCalls(n *sitter.Node, src []byte, out *[]rawCall) {
	switch n.Kind() {
	case "call_expression":
		if fnN := n.ChildByFieldName("function"); fnN != nil {
			switch fnN.Kind() {
			case "identifier":
				name := fnN.Utf8Text(src)
				if name != "require" && name != "import" {
					*out = append(*out, rawCall{name: name, arity: -1, rng: rangeOf(fnN)})
				}
			case "member_expression":
				obj := fnN.ChildByFieldName("object")
				prop := fnN.ChildByFieldName("property")
				if obj != nil && prop != nil && obj.Kind() == "identifier" {
					*out = append(*out, rawCall{
						object: obj.Utf8Text(src),
						name:   prop.Utf8Text(src),
						arity:  -1,
						rng:    rangeOf(fnN),
					})
				}
			}
		}
	case "jsx_self_closing_element", "jsx_opening_element":
		if nameN := n.ChildByFieldName("name"); nameN != nil {
			text := nameN.Utf8Text(src)
			parts := strings.Split(text, ".")
			switch {
			case len(parts) == 1 && startsUpper(text):
				*out = append(*out, rawCall{name: text, arity: -1, rng: rangeOf(nameN)})
			case len(parts) == 2 && startsUpper(parts[0]):
				*out = append(*out, rawCall{object: parts[0], name: parts[1], arity: -1, rng: rangeOf(nameN)})
			}
		}
	}
	for i := uint(0); i < n.NamedChildCount(); i++ {
		if c := n.NamedChild(i); c != nil {
			jsCalls(c, src, out)
		}
	}
}

func jsImport(fp *fileParse, stmt *sitter.Node, src []byte) {
	srcN := stmt.ChildByFieldName("source")
	if srcN == nil {
		return
	}
	spec := strings.Trim(srcN.Utf8Text(src), "'\"`")

	for _, c := range namedChildren(stmt) {
		if c.Kind() != "import_clause" {
			continue
		}
		for _, p := range namedChildren(&c) {
			p := p
			switch p.Kind() {
			case "identifier":
				fp.jsImports[p.Utf8Text(src)] = importRef{spec: spec, name: "default"}
			case "namespace_import":
				for k := uint(0); k < p.NamedChildCount(); k++ {
					if id := p.NamedChild(k); id != nil && id.Kind() == "identifier" {
						fp.jsImports[id.Utf8Text(src)] = importRef{spec: spec, name: "*"}
					}
				}
			case "named_imports":
				for _, s := range namedChildren(&p) {
					if s.Kind() != "import_specifier" {
						continue
					}
					nameN := s.ChildByFieldName("name")
					if nameN == nil {
						continue
					}
					local := nameN
					if aliasN := s.ChildByFieldName("alias"); aliasN != nil {
						local = aliasN
					}
					fp.jsImports[local.Utf8Text(src)] = importRef{spec: spec, name: nameN.Utf8Text(src)}
				}
			}
		}
	}
}

func (fp *fileParse) defaultRecord() *record {
	for _, r := range fp.records {
		if r.isDefault {
			return r
		}
	}
	if fp.defaultName != "" {
		return fp.byName[fp.defaultName]
	}
	return nil
}

func startsUpper(s string) bool {
	for _, r := range s {
		return unicode.IsUpper(r)
	}
	return false
}
