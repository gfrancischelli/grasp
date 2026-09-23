package indexer

import (
	"path/filepath"
	"strings"

	sitter "github.com/tree-sitter/go-tree-sitter"
	ts_ex "github.com/tree-sitter/tree-sitter-elixir/bindings/go"
	ts_go "github.com/tree-sitter/tree-sitter-go/bindings/go"
	ts_js "github.com/tree-sitter/tree-sitter-javascript/bindings/go"
	ts_ts "github.com/tree-sitter/tree-sitter-typescript/bindings/go"
)

var (
	langJS  = sitter.NewLanguage(ts_js.Language())
	langTS  = sitter.NewLanguage(ts_ts.LanguageTypescript())
	langTSX = sitter.NewLanguage(ts_ts.LanguageTSX())
	langEx  = sitter.NewLanguage(ts_ex.Language())
	langGo  = sitter.NewLanguage(ts_go.Language())
)

// LanguageFor picks the grammar for a path; nil means "not indexable".
func LanguageFor(path string) *sitter.Language {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ts", ".mts", ".cts":
		return langTS
	case ".tsx":
		return langTSX
	case ".js", ".jsx", ".mjs", ".cjs":
		return langJS
	case ".ex", ".exs":
		return langEx
	case ".go":
		return langGo
	}
	return nil
}

func languageID(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ts", ".mts", ".cts", ".tsx", ".js", ".jsx", ".mjs", ".cjs":
		return "js"
	case ".ex", ".exs":
		return "elixir"
	case ".go":
		return "go"
	}
	return ""
}

// rawCall is an unresolved call site. object carries the qualifier when there
// is one: a JS member object, an Elixir (aliased) module, a Go selector
// operand. arity is -1 when the call form does not say.
type rawCall struct {
	object string
	name   string
	arity  int
	rng    Range
}

// record is one extracted function plus what resolution needs.
type record struct {
	fn        *Function
	localName string // resolution key within the file/module
	isDefault bool   // JS: the file's `export default`
	rawCalls  []rawCall
}

type moduleDecl struct {
	name string
	line int
}

// importRef maps a JS local identifier to where it was imported from.
type importRef struct {
	spec string // literal import source ("./x", "react", …)
	name string // exported name, "default", or "*"
}

// exImport is one Elixir `import Module` (optionally with only:).
type exImport struct {
	module  string
	only    map[string]bool // "name/arity"
	hasOnly bool
}

type fileParse struct {
	relPath string
	lang    string
	module  string // path-derived; Elixir records carry their defmodule instead
	records []*record
	byName  map[string]*record
	modules []moduleDecl
	lines   []string

	// js
	jsImports   map[string]importRef
	defaultName string

	// elixir
	exAliases map[string]string
	exImports []exImport

	// go
	goImports map[string]string // local package name -> import path
	goDir     string            // package directory, relative
}

func moduleNameFor(relPath string) string {
	p := strings.TrimSuffix(relPath, filepath.Ext(relPath))
	return strings.ReplaceAll(p, "/", ".")
}

// parseFile extracts function records and raw call sites from one file,
// dispatching on language. The parser is reused by the caller; the tree is
// closed before returning.
func parseFile(parser *sitter.Parser, relPath string, src []byte) *fileParse {
	lang := LanguageFor(relPath)
	if lang == nil {
		return nil
	}
	if err := parser.SetLanguage(lang); err != nil {
		return nil
	}
	tree := parser.Parse(src, nil)
	if tree == nil {
		return nil
	}
	defer tree.Close()

	fp := &fileParse{
		relPath:   relPath,
		lang:      languageID(relPath),
		module:    moduleNameFor(relPath),
		byName:    map[string]*record{},
		jsImports: map[string]importRef{},
		exAliases: map[string]string{},
		goImports: map[string]string{},
		goDir:     filepath.Dir(relPath),
		lines:     strings.Split(string(src), "\n"),
	}

	root := tree.RootNode()
	switch fp.lang {
	case "js":
		extractJS(fp, root, src)
	case "elixir":
		extractElixir(fp, root, src)
	case "go":
		extractGo(fp, root, src)
	}

	if len(fp.modules) == 0 && len(fp.records) > 0 {
		fp.modules = append(fp.modules, moduleDecl{name: fp.module, line: 1})
	}
	return fp
}

// newRecord builds a Function and registers it. key is the per-file
// resolution name (JS localName, Go name, Elixir id).
func (fp *fileParse) newRecord(module, name, key string, arity int, arities []int, kind string, startLine, endLine int) *record {
	if arities == nil {
		arities = []int{arity}
	}
	fn := &Function{
		ID:          module + "." + name + "/" + itoa(arity),
		Module:      module,
		Name:        name,
		Arity:       arity,
		Arities:     arities,
		Kind:        kind,
		File:        fp.relPath,
		Span:        Span{StartLine: startLine, EndLine: endLine},
		Source:      fp.sourceLines(startLine, endLine),
		Change:      "unchanged",
		Calls:       []Call{},
		HiddenCalls: []Call{},
	}
	rec := &record{fn: fn, localName: name}
	fp.records = append(fp.records, rec)
	if key != "" {
		fp.byName[key] = rec
	}
	return rec
}

func (fp *fileParse) sourceLines(start, end int) string {
	if start < 1 {
		start = 1
	}
	if end > len(fp.lines) {
		end = len(fp.lines)
	}
	if start > end {
		return ""
	}
	return strings.Join(fp.lines[start-1:end], "\n")
}

func namedChildren(n *sitter.Node) []sitter.Node {
	cursor := n.Walk()
	children := n.NamedChildren(cursor)
	cursor.Close()
	return children
}

func rangeOf(n *sitter.Node) Range {
	s, e := n.StartPosition(), n.EndPosition()
	return Range{
		Start: [2]int{int(s.Row) + 1, int(s.Column) + 1},
		End:   [2]int{int(e.Row) + 1, int(e.Column) + 1},
	}
}

func itoa(n int) string {
	if n < 0 {
		return "?"
	}
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
