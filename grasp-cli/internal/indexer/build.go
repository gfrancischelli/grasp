package indexer

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	sitter "github.com/tree-sitter/go-tree-sitter"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
)

type Options struct {
	// Root is the tree to index — the checkout, or a PR worktree.
	Root string
	// OutPath is where index.json is written; empty writes
	// <Root>/.grasp/index.json. A PR review passes the main checkout's path
	// here so the viewer watching it picks the worktree's index up.
	OutPath string
	// BaseRef classifies functions against merge-base(HEAD, BaseRef).
	// Empty skips classification (everything "unchanged").
	BaseRef string
	// Review, when set, records what PR this index reviews.
	Review *Review
	Log    func(string)
}

const maxFileSize = 512 * 1024

// Build indexes the tree at opts.Root and writes the index.json document.
func Build(opts Options) (*Index, error) {
	log := opts.Log
	if log == nil {
		log = func(string) {}
	}
	root, err := filepath.Abs(opts.Root)
	if err != nil {
		return nil, err
	}

	paths, err := gitx.ListFiles(root)
	if err != nil {
		return nil, err
	}
	var indexable []string
	for _, p := range paths {
		if LanguageFor(p) == nil || strings.Contains(p, "node_modules/") {
			continue
		}
		if strings.HasSuffix(p, ".min.js") || strings.HasSuffix(p, ".dist.js") {
			continue
		}
		indexable = append(indexable, p)
	}
	log(fmt.Sprintf("parsing %d files", len(indexable)))

	files := parseAll(root, indexable)
	resolveAll(files, resolveContext{goModule: readGoModule(root)})

	idx := &Index{
		Version:     1,
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Project:     projectInfo(root, files),
		Review:      opts.Review,
		Functions:   []*Function{},
		EntryPoints: []EntryPoint{},
	}

	if opts.BaseRef != "" {
		if err := classify(root, opts.BaseRef, files, idx, log); err != nil {
			return nil, err
		}
	} else {
		branch, _ := gitx.Branch(root)
		head, _ := gitx.Head(root)
		idx.Git = GitInfo{Branch: branch, Head: head}
	}

	assemble(files, idx)

	out := opts.OutPath
	if out == "" {
		out = filepath.Join(root, ".grasp", "index.json")
	}
	if err := writeJSON(out, idx); err != nil {
		return nil, err
	}
	log(fmt.Sprintf("indexed %d functions in %d modules → %s", len(idx.Functions), len(idx.Modules), out))
	return idx, nil
}

func parseAll(root string, paths []string) map[string]*fileParse {
	files := make(map[string]*fileParse, len(paths))
	var mu sync.Mutex
	var wg sync.WaitGroup
	jobs := make(chan string)

	workers := runtime.NumCPU()
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			parser := sitter.NewParser()
			defer parser.Close()
			for rel := range jobs {
				src, err := os.ReadFile(filepath.Join(root, rel))
				if err != nil || len(src) > maxFileSize {
					continue
				}
				if fp := parseFile(parser, rel, src); fp != nil {
					mu.Lock()
					files[rel] = fp
					mu.Unlock()
				}
			}
		}()
	}
	for _, p := range paths {
		jobs <- p
	}
	close(jobs)
	wg.Wait()
	return files
}

// classify marks every function added/modified/unchanged against the merge
// base, carries base_source for modified ones, and appends removed records
// parsed out of the base's blobs.
func classify(root, baseRef string, files map[string]*fileParse, idx *Index, log func(string)) error {
	mb, err := gitx.MergeBase(root, baseRef)
	if err != nil {
		return fmt.Errorf("cannot find merge base with %s: %w", baseRef, err)
	}
	branch, _ := gitx.Branch(root)
	head, _ := gitx.Head(root)
	idx.Git = GitInfo{BaseRef: baseRef, BaseSha: mb, Branch: branch, Head: head}

	statuses, err := gitx.FileStatus(root, mb)
	if err != nil {
		return err
	}

	parser := sitter.NewParser()
	defer parser.Close()
	changed := 0

	for rel, status := range statuses {
		if LanguageFor(rel) == nil {
			continue
		}
		switch status {
		case "A":
			if f, ok := files[rel]; ok {
				for _, r := range f.records {
					r.fn.Change = "added"
					changed++
				}
			}
		case "D":
			blob, err := gitx.ShowBlob(root, mb, rel)
			if err != nil {
				continue
			}
			if base := parseFile(parser, rel, blob); base != nil {
				appendRemoved(idx, base, base.records)
				changed += len(base.records)
			}
		case "M":
			f, ok := files[rel]
			if !ok {
				continue
			}
			blob, err := gitx.ShowBlob(root, mb, rel)
			if err != nil {
				continue
			}
			base := parseFile(parser, rel, blob)
			if base == nil {
				continue
			}
			lines, err := gitx.ChangedLines(root, mb, rel)
			if err != nil {
				continue
			}
			baseExact := map[string]*record{}
			baseLoose := map[string][]*record{}
			for _, br := range base.records {
				baseExact[recordKey(br)] = br
				baseLoose[looseKey(br)] = append(baseLoose[looseKey(br)], br)
			}
			matched := map[*record]bool{}
			for _, r := range f.records {
				br := baseExact[recordKey(r)]
				if br == nil {
					// The arity changed but the name is unambiguous: still the
					// same function, modified rather than removed + added.
					if lst := baseLoose[looseKey(r)]; len(lst) == 1 {
						br = lst[0]
					}
				}
				if br != nil {
					matched[br] = true
				}
				switch {
				case br == nil:
					r.fn.Change = "added"
					changed++
				case overlaps(lines, r.fn.Span) || br.fn.Source != r.fn.Source:
					r.fn.Change = "modified"
					src := br.fn.Source
					r.fn.BaseSource = &src
					changed++
				}
			}
			var removed []*record
			for _, br := range base.records {
				if !matched[br] {
					removed = append(removed, br)
				}
			}
			appendRemoved(idx, base, removed)
			changed += len(removed)
		}
	}
	log(fmt.Sprintf("classified against %s (%.8s): %d changed functions", baseRef, mb, changed))
	return nil
}

func appendRemoved(idx *Index, base *fileParse, records []*record) {
	for _, r := range records {
		r.fn.Change = "removed"
		r.fn.Removed = true
		r.fn.Calls = []Call{}
		idx.Functions = append(idx.Functions, r.fn)
	}
}

func recordKey(r *record) string {
	return r.fn.Module + "|" + r.localName + "/" + itoa(r.fn.Arity)
}

func looseKey(r *record) string {
	return r.fn.Module + "|" + r.localName
}

func overlaps(lines map[int]bool, span Span) bool {
	for l := span.StartLine; l <= span.EndLine; l++ {
		if lines[l] {
			return true
		}
	}
	return false
}

func assemble(files map[string]*fileParse, idx *Index) {
	rels := make([]string, 0, len(files))
	for rel := range files {
		rels = append(rels, rel)
	}
	sort.Strings(rels)

	seen := map[string]bool{}
	for _, rel := range rels {
		f := files[rel]
		if len(f.records) == 0 {
			continue
		}
		for _, m := range f.modules {
			if !seen[m.name] {
				seen[m.name] = true
				idx.Modules = append(idx.Modules, Module{Name: m.name, File: rel, Line: m.line, Behaviours: []string{}})
			}
		}
		for _, r := range f.records {
			idx.Functions = append(idx.Functions, r.fn)
		}
	}
	// Removed functions were appended before assemble; their modules may not
	// exist anymore in the parsed set.
	for _, fn := range idx.Functions {
		if fn.Removed && !seen[fn.Module] {
			seen[fn.Module] = true
			idx.Modules = append(idx.Modules, Module{Name: fn.Module, File: fn.File, Line: 1, Behaviours: []string{}})
		}
	}
	sort.SliceStable(idx.Functions, func(i, j int) bool {
		a, b := idx.Functions[i], idx.Functions[j]
		if a.File != b.File {
			return a.File < b.File
		}
		return a.Span.StartLine < b.Span.StartLine
	})
	sort.SliceStable(idx.Modules, func(i, j int) bool { return idx.Modules[i].Name < idx.Modules[j].Name })
}

func projectInfo(root string, files map[string]*fileParse) Project {
	app := filepath.Base(root)
	if data, err := os.ReadFile(filepath.Join(root, "package.json")); err == nil {
		var pkg struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(data, &pkg) == nil && pkg.Name != "" {
			app = pkg.Name
		}
	}
	langSet := map[string]bool{}
	for _, f := range files {
		langSet[f.lang] = true
	}
	var langs []string
	for _, l := range []string{"elixir", "go", "js"} {
		if langSet[l] {
			langs = append(langs, l)
		}
	}
	return Project{App: app, Root: root, Languages: langs}
}

// readGoModule reads the module path from go.mod, the anchor for resolving
// this project's internal Go imports.
func readGoModule(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(line, "module "); ok {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}

// writeJSON writes atomically (temp file + rename) so a viewer watching the
// path never reads a half-written document.
func writeJSON(path string, idx *Index) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(idx)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
