package indexer

import (
	"strings"

	sitter "github.com/tree-sitter/go-tree-sitter"
)

// extractGo walks a Go file's top level: function declarations, methods
// (named "Receiver.Method"), func-literal variables, and imports. Resolution
// works at package granularity — a plain call resolves across the files of
// the same directory, a selector through the file's imports when the path is
// inside this module.
func extractGo(fp *fileParse, root *sitter.Node, src []byte) {
	for _, c := range namedChildren(root) {
		c := c
		switch c.Kind() {
		case "function_declaration":
			name := c.ChildByFieldName("name")
			if name == nil {
				continue
			}
			goRecord(fp, name.Utf8Text(src), &c, src)

		case "method_declaration":
			name := c.ChildByFieldName("name")
			recv := c.ChildByFieldName("receiver")
			if name == nil || recv == nil {
				continue
			}
			rt := receiverType(recv, src)
			if rt == "" {
				continue
			}
			goRecord(fp, rt+"."+name.Utf8Text(src), &c, src)

		case "var_declaration":
			for _, spec := range namedChildren(&c) {
				if spec.Kind() != "var_spec" {
					continue
				}
				nameN := spec.ChildByFieldName("name")
				value := spec.ChildByFieldName("value")
				if nameN == nil || value == nil {
					continue
				}
				if fn := childOfKind(value, "func_literal"); fn != nil {
					spec := spec
					goRecordAt(fp, nameN.Utf8Text(src), fn, &spec, src)
				}
			}

		case "import_declaration":
			goImports(fp, &c, src)
		}
	}
}

func goRecord(fp *fileParse, name string, decl *sitter.Node, src []byte) {
	goRecordAt(fp, name, decl, decl, src)
}

func goRecordAt(fp *fileParse, name string, funcNode, spanNode *sitter.Node, src []byte) {
	if _, dup := fp.byName[name]; dup {
		return
	}
	kind := "defp"
	if startsUpper(name) || (strings.Contains(name, ".") && startsUpper(lastSegment(name))) {
		kind = "def" // exported identifier
	}
	start := int(spanNode.StartPosition().Row) + 1
	end := int(spanNode.EndPosition().Row) + 1
	rec := fp.newRecord(fp.module, name, name, goParams(funcNode), nil, kind, start, end)
	if body := funcNode.ChildByFieldName("body"); body != nil {
		goCalls(body, src, &rec.rawCalls)
	}
}

func receiverType(recv *sitter.Node, src []byte) string {
	for _, d := range namedChildren(recv) {
		if d.Kind() != "parameter_declaration" {
			continue
		}
		t := d.ChildByFieldName("type")
		if t == nil {
			continue
		}
		switch t.Kind() {
		case "pointer_type":
			if inner := firstNamed(t); inner != nil {
				return typeName(inner, src)
			}
		default:
			return typeName(t, src)
		}
	}
	return ""
}

func typeName(t *sitter.Node, src []byte) string {
	if t.Kind() == "generic_type" {
		if inner := t.ChildByFieldName("type"); inner != nil {
			return inner.Utf8Text(src)
		}
	}
	return t.Utf8Text(src)
}

func goParams(funcNode *sitter.Node) int {
	params := funcNode.ChildByFieldName("parameters")
	if params == nil {
		return 0
	}
	n := 0
	for _, d := range namedChildren(params) {
		switch d.Kind() {
		case "parameter_declaration", "variadic_parameter_declaration":
			names := 0
			for i := uint(0); i < d.NamedChildCount(); i++ {
				if d.FieldNameForNamedChild(uint32(i)) == "name" {
					names++
				}
			}
			if names == 0 {
				names = 1 // unnamed parameter: just a type
			}
			n += names
		}
	}
	return n
}

func goCalls(n *sitter.Node, src []byte, out *[]rawCall) {
	if n.Kind() == "call_expression" {
		if fnN := n.ChildByFieldName("function"); fnN != nil {
			switch fnN.Kind() {
			case "identifier":
				*out = append(*out, rawCall{name: fnN.Utf8Text(src), arity: -1, rng: rangeOf(fnN)})
			case "selector_expression":
				op := fnN.ChildByFieldName("operand")
				field := fnN.ChildByFieldName("field")
				if op != nil && field != nil && op.Kind() == "identifier" {
					*out = append(*out, rawCall{
						object: op.Utf8Text(src),
						name:   field.Utf8Text(src),
						arity:  -1,
						rng:    rangeOf(fnN),
					})
				}
			}
		}
	}
	for i := uint(0); i < n.NamedChildCount(); i++ {
		if c := n.NamedChild(i); c != nil {
			goCalls(c, src, out)
		}
	}
}

func goImports(fp *fileParse, decl *sitter.Node, src []byte) {
	var handleSpec func(spec *sitter.Node)
	handleSpec = func(spec *sitter.Node) {
		switch spec.Kind() {
		case "import_spec":
			pathN := spec.ChildByFieldName("path")
			if pathN == nil {
				return
			}
			path := strings.Trim(pathN.Utf8Text(src), "\"`")
			local := lastSlashSegment(path)
			if nameN := spec.ChildByFieldName("name"); nameN != nil {
				local = nameN.Utf8Text(src)
			}
			if local != "_" && local != "." {
				fp.goImports[local] = path
			}
		case "import_spec_list":
			for _, s := range namedChildren(spec) {
				s := s
				handleSpec(&s)
			}
		}
	}
	for _, c := range namedChildren(decl) {
		c := c
		handleSpec(&c)
	}
}

func lastSlashSegment(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}
