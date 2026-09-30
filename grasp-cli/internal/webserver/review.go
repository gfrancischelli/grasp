package webserver

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/publish"
)

// Nothing syncs to GitHub on its own: these endpoints fire only from explicit
// gestures — a thread's "send to GitHub" button, the composer's send variant,
// or the header's send-review box with its final considerations.

func (s *Server) reviewRoot() string {
	return filepath.Dir(filepath.Dir(s.Comments.Path))
}

func (s *Server) reviewPR() (int, string, error) {
	root := s.reviewRoot()
	if idx, _, _, err := s.loadIndex(); err == nil && idx.Review != nil && idx.Review.PR > 0 {
		return idx.Review.PR, root, nil
	}
	n, err := publish.CurrentPR(root)
	return n, root, err
}

// handlePublish sends one thread ({"thread": id}) or every unpublished one
// ({}) to the pull request as review comments.
func (s *Server) handlePublish(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Thread string `json:"thread"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	number, root, err := s.reviewPR()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var log []string
	logf := func(l string) { log = append(log, l) }

	if req.Thread != "" {
		if err := publish.RunThread(root, number, req.Thread, logf); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
	} else {
		sum, err := publish.Run(root, number, logf)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		logf(formatSummary(sum))
	}
	doc, _ := s.Comments.Load()
	writeJSON(w, map[string]any{"pr": number, "log": log, "comments": doc})
}

// handleReview is the "send review to GitHub" box: publishes every
// unpublished thread and, when final considerations were written, posts them
// as a top-level review comment on the pull request.
func (s *Server) handleReview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Body string `json:"body"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	number, root, err := s.reviewPR()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var log []string
	logf := func(l string) { log = append(log, l) }

	sum, err := publish.Run(root, number, logf)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	logf(formatSummary(sum))
	if req.Body != "" {
		url, err := publish.SubmitReview(root, number, req.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		logf("review comment → " + url)
	}
	doc, _ := s.Comments.Load()
	writeJSON(w, map[string]any{"pr": number, "log": log, "comments": doc})
}

func formatSummary(sum publish.Summary) string {
	return fmt.Sprintf("published %d, skipped %d already published, %d failed",
		sum.Published, sum.Skipped, sum.Failed)
}
