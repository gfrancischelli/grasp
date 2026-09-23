package webserver

import (
	"strings"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/comments"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/indexer"
)

// Re-anchoring keeps threads on the code they are about while the code moves
// under them — a new push reviewed with grasp pr, an agent edit, more work on
// the branch. Whenever the index is reparsed, every thread is checked: one
// whose line still carries its anchor text stays; one whose line moved is
// followed to wherever that text went; one that matches nowhere is marked
// outdated (it sits in the card's footer); one whose function has left the
// index is an orphan (listed muted in the sidebar, drawing nothing).

func (s *Server) reanchorAll(byID map[string]*indexer.Function) {
	_, _ = s.Comments.Mutate(func(doc *comments.Doc) error {
		for _, t := range doc.Threads {
			reanchorThread(t, byID)
		}
		return nil
	})
}

func reanchorThread(t *comments.Thread, byID map[string]*indexer.Function) {
	fn := byID[t.Function]
	if fn == nil {
		// The arity may have changed, renaming the id: match the same
		// module.name in the same file.
		if cut := strings.LastIndexByte(t.Function, '/'); cut > 0 {
			prefix := t.Function[:cut+1]
			for id, f := range byID {
				if f.File == t.File && strings.HasPrefix(id, prefix) {
					fn, t.Function = f, id
					break
				}
			}
		}
	}
	if fn == nil {
		t.Status = "orphan"
		return
	}

	lines, start, ok := threadLines(fn, t.Side)
	if !ok {
		t.Status = "outdated"
		return
	}
	at := func(n int) (string, bool) {
		i := n - start
		if i < 0 || i >= len(lines) {
			return "", false
		}
		return strings.TrimSpace(lines[i]), true
	}

	cur, inRange := at(t.Line)
	if t.Anchor == "" {
		// A thread from before anchors existed: adopt the text under it now.
		if inRange {
			t.Anchor, t.Status = cur, ""
		} else {
			t.Status = "outdated"
		}
		return
	}
	if inRange && cur == t.Anchor {
		t.Status = ""
		return
	}

	// The line moved: follow the anchor text to its nearest occurrence.
	best := -1
	for i, l := range lines {
		if strings.TrimSpace(l) != t.Anchor {
			continue
		}
		n := start + i
		if best == -1 || absInt(n-t.Line) < absInt(best-t.Line) {
			best = n
		}
	}
	if best == -1 {
		t.Status = "outdated"
		return
	}
	if t.EndLine > 0 {
		t.EndLine += best - t.Line
	}
	t.Line = best
	t.Status = ""
}

// threadLines returns the text a side's line numbers index into: the current
// source (absolute lines) for the new side, the base version (function-
// relative lines) for the base side — which a removed function's source is.
func threadLines(fn *indexer.Function, side string) ([]string, int, bool) {
	if side == "base" {
		if fn.Removed {
			return strings.Split(fn.Source, "\n"), fn.Span.StartLine, true
		}
		if fn.BaseSource == nil {
			return nil, 0, false // no longer modified: base lines mean nothing
		}
		return strings.Split(*fn.BaseSource, "\n"), 1, true
	}
	if fn.Removed {
		return nil, 0, false
	}
	return strings.Split(fn.Source, "\n"), fn.Span.StartLine, true
}

// anchorFor captures the trimmed text of the line a new thread points at.
func (s *Server) anchorFor(fnID string, line int, side string) string {
	_, byID, _, err := s.loadIndex()
	if err != nil {
		return ""
	}
	fn := byID[fnID]
	if fn == nil {
		return ""
	}
	lines, start, ok := threadLines(fn, normalizeSide(side))
	if !ok {
		return ""
	}
	i := line - start
	if i < 0 || i >= len(lines) {
		return ""
	}
	return strings.TrimSpace(lines[i])
}

func normalizeSide(side string) string {
	if side == "base" {
		return "base"
	}
	return "new"
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
