package indexer

import (
	"path"
	"strings"
)

type resolveContext struct {
	goModule string // module path from go.mod, for resolving internal imports
}

// resolveAll turns every file's raw call sites into Call entries pointing at
// indexed function ids. Heuristic per language, dropping what it cannot place
// with confidence: a wrong edge misleads a review more than a missing one.
func resolveAll(files map[string]*fileParse, ctx resolveContext) {
	// JS: global name table for the unique-match fallback.
	jsByName := map[string][]*record{}
	// Elixir: exact module|name/arity plus per-module name lists.
	exExact := map[string]*record{}
	exByName := map[string][]*record{}
	// Go: package-directory tables.
	goDirs := map[string]map[string]*record{}

	for _, f := range files {
		for _, r := range f.records {
			switch f.lang {
			case "js":
				jsByName[r.localName] = append(jsByName[r.localName], r)
			case "elixir":
				for _, a := range r.fn.Arities {
					key := r.fn.Module + "|" + r.localName + "/" + itoa(a)
					if _, taken := exExact[key]; !taken {
						exExact[key] = r
					}
				}
				exByName[r.fn.Module+"|"+r.localName] = append(exByName[r.fn.Module+"|"+r.localName], r)
			case "go":
				dir := goDirs[f.goDir]
				if dir == nil {
					dir = map[string]*record{}
					goDirs[f.goDir] = dir
				}
				if _, taken := dir[r.localName]; !taken {
					dir[r.localName] = r
				}
			}
		}
	}

	for _, f := range files {
		for _, r := range f.records {
			for _, c := range r.rawCalls {
				var target *record
				switch f.lang {
				case "js":
					target = resolveJS(f, c, files, jsByName)
				case "elixir":
					target = resolveEx(f, r, c, exExact, exByName)
				case "go":
					target = resolveGo(f, c, goDirs, ctx.goModule)
				}
				if target == nil || target == r {
					continue
				}
				kind := "remote"
				if target.fn.Module == r.fn.Module {
					kind = "local"
				}
				r.fn.Calls = append(r.fn.Calls, Call{Kind: kind, Target: target.fn.ID, Range: c.rng})
			}
		}
	}
}

// --- JavaScript / TypeScript ---

// resolveJS, in order of confidence: a name defined in the same file
// (including `Class.method`); a name imported from another project file
// (default, named or namespace); a name defined exactly once project-wide.
func resolveJS(f *fileParse, c rawCall, files map[string]*fileParse, byName map[string][]*record) *record {
	if c.object == "" {
		if r := f.byName[c.name]; r != nil {
			return r
		}
		if ref, ok := f.jsImports[c.name]; ok {
			if tf := resolveSpec(f, ref.spec, files); tf != nil {
				if ref.name == "default" {
					return tf.defaultRecord()
				}
				return tf.byName[ref.name]
			}
			return nil // imported, but external to the project
		}
		if lst := byName[c.name]; len(lst) == 1 {
			return lst[0]
		}
		return nil
	}
	// `X.m()` — X as a namespace or default import of a project file.
	if ref, ok := f.jsImports[c.object]; ok {
		if tf := resolveSpec(f, ref.spec, files); tf != nil {
			return tf.byName[c.name]
		}
		return nil
	}
	// `X.m()` — method of a class in the same file.
	return f.byName[c.object+"."+c.name]
}

var indexableJSExts = []string{".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}

// resolveSpec resolves a relative import specifier to a parsed project file.
// Package imports (react, lodash, aliases) return nil.
func resolveSpec(from *fileParse, spec string, files map[string]*fileParse) *fileParse {
	if !strings.HasPrefix(spec, ".") {
		return nil
	}
	base := path.Join(path.Dir(from.relPath), spec)
	candidates := []string{base}
	for _, ext := range indexableJSExts {
		candidates = append(candidates, base+ext)
	}
	for _, ext := range indexableJSExts {
		candidates = append(candidates, path.Join(base, "index"+ext))
	}
	for _, cand := range candidates {
		if f, ok := files[cand]; ok {
			return f
		}
	}
	return nil
}

// --- Elixir ---

// resolveEx: a bare call resolves in the record's own module then through
// imports; a qualified call expands the alias and resolves in that module.
// Arity matches exactly first (default arities included), then falls back to
// the single function of that name — which absorbs pipes, whose written
// argument count is one short.
func resolveEx(f *fileParse, r *record, c rawCall, exact map[string]*record, byName map[string][]*record) *record {
	lookup := func(module string) *record {
		if c.arity >= 0 {
			if t := exact[module+"|"+c.name+"/"+itoa(c.arity)]; t != nil {
				return t
			}
			// One argument more than written: the |> pipe's hidden first arg.
			if t := exact[module+"|"+c.name+"/"+itoa(c.arity+1)]; t != nil {
				return t
			}
		}
		if lst := byName[module+"|"+c.name]; len(lst) == 1 {
			return lst[0]
		}
		return nil
	}

	if c.object == "" {
		if t := lookup(r.fn.Module); t != nil {
			return t
		}
		for _, imp := range f.exImports {
			if imp.hasOnly {
				if c.arity >= 0 && !imp.only[c.name+"/"+itoa(c.arity)] && !imp.only[c.name+"/"+itoa(c.arity+1)] {
					continue
				}
			}
			if t := lookup(imp.module); t != nil {
				return t
			}
		}
		return nil
	}

	module := c.object
	if segs := strings.SplitN(module, ".", 2); true {
		head := segs[0]
		if head == "__MODULE__" {
			module = r.fn.Module
			if len(segs) == 2 {
				module += "." + segs[1]
			}
		} else if full, ok := f.exAliases[head]; ok {
			module = full
			if len(segs) == 2 {
				module += "." + segs[1]
			}
		}
	}
	return lookup(module)
}

// --- Go ---

// resolveGo: a plain call resolves across the files of the same package
// directory; `pkg.Fn(…)` resolves through the file's imports when the import
// path lives inside this module. Selector calls on variables (method calls)
// need type information and are skipped.
func resolveGo(f *fileParse, c rawCall, dirs map[string]map[string]*record, goModule string) *record {
	if c.object == "" {
		if pkg := dirs[f.goDir]; pkg != nil {
			return pkg[c.name]
		}
		return nil
	}
	importPath, ok := f.goImports[c.object]
	if !ok || goModule == "" {
		return nil
	}
	var rel string
	switch {
	case importPath == goModule:
		rel = "."
	case strings.HasPrefix(importPath, goModule+"/"):
		rel = strings.TrimPrefix(importPath, goModule+"/")
	default:
		return nil // external dependency
	}
	if pkg := dirs[rel]; pkg != nil {
		return pkg[c.name]
	}
	return nil
}
