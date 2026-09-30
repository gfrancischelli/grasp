// Package indexer builds the call-graph index every other part of grasp reads.
//
// The output is the grasp upstream index.json v1 schema: the viewer draws it,
// the palette searches it, and the MCP tools answer from it. Anything able to
// produce this document can replace this indexer, and any viewer able to read
// it can replace the canvas.
package indexer

// Index is the root of the index.json document (schema version 1, compatible
// with gfrancischelli/grasp).
type Index struct {
	Version     int          `json:"version"`
	GeneratedAt string       `json:"generated_at"`
	Project     Project      `json:"project"`
	Git         GitInfo      `json:"git"`
	Review      *Review      `json:"review,omitempty"`
	Modules     []Module     `json:"modules"`
	Functions   []*Function  `json:"functions"`
	EntryPoints []EntryPoint `json:"entry_points"`
}

// Review carries what is being reviewed when the index was built by
// `grasp pr` — the viewer names the session after it and shows the title.
type Review struct {
	PR    int    `json:"pr,omitempty"`
	Title string `json:"title,omitempty"`
	URL   string `json:"url,omitempty"`
}

type Project struct {
	App       string   `json:"app"`
	Root      string   `json:"root"`
	Languages []string `json:"languages,omitempty"`
}

type GitInfo struct {
	BaseRef string `json:"base_ref"`
	BaseSha string `json:"base_sha"`
	Branch  string `json:"branch"`
	Head    string `json:"head"`
}

// Module groups functions in the sidebar. For JS/TS a module is a file; the
// name is the relative path with slashes turned into dots ("src.gql.index").
type Module struct {
	Name       string   `json:"name"`
	File       string   `json:"file"`
	Line       int      `json:"line"`
	Behaviours []string `json:"behaviours"`
}

type Span struct {
	StartLine int `json:"start_line"`
	EndLine   int `json:"end_line"`
}

// Range is a clickable region in the source: [line, column], both 1-based,
// end column exclusive — matching the upstream document.
type Range struct {
	Start [2]int `json:"start"`
	End   [2]int `json:"end"`
}

type Call struct {
	Kind   string `json:"kind"` // "local" (same module) | "remote"
	Target string `json:"target"`
	Range  Range  `json:"range"`
}

type Function struct {
	ID          string  `json:"id"` // "<module>.<name>/<arity>"
	Module      string  `json:"module"`
	Name        string  `json:"name"`
	Arity       int     `json:"arity"`
	Arities     []int   `json:"arities"`
	Kind        string  `json:"kind"` // "def" (exported) | "defp" (file-local)
	File        string  `json:"file"`
	Span        Span    `json:"span"`
	Source      string  `json:"source"`
	BaseSource  *string `json:"base_source"`
	Change      string  `json:"change"` // added | modified | unchanged | removed
	Removed     bool    `json:"removed"`
	Calls       []Call  `json:"calls"`
	HiddenCalls []Call  `json:"hidden_calls"`
}

type EntryPoint struct {
	Kind   string            `json:"kind"`
	Label  string            `json:"label"`
	Target string            `json:"target"`
	Meta   map[string]string `json:"meta"`
}
