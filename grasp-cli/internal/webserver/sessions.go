package webserver

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// A session is one canvas: the cards on it, where each sits, its view state,
// pan and zoom. Each is a file under .grasp/sessions/ in the checkout the
// review was started from, written a moment after the canvas changes and read
// back when the viewer opens, so quitting and coming back finds the cards
// where they were. The document itself is the client's; the server stores it
// verbatim.
var sessionName = regexp.MustCompile(`^[A-Za-z0-9_-]{1,40}$`)

func (s *Server) sessionsDir() string {
	return filepath.Join(filepath.Dir(s.Comments.Path), "sessions")
}

// sessions handles /api/sessions and /api/sessions/{name}.
func (s *Server) sessions(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/api/sessions")
	name = strings.TrimPrefix(name, "/")

	if name == "" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		entries, _ := os.ReadDir(s.sessionsDir())
		names := []string{}
		for _, e := range entries {
			if n, ok := strings.CutSuffix(e.Name(), ".json"); ok && sessionName.MatchString(n) {
				names = append(names, n)
			}
		}
		sort.Strings(names)
		writeJSON(w, map[string]any{"sessions": names})
		return
	}

	if !sessionName.MatchString(name) {
		http.Error(w, "session names are letters, digits, - and _, up to 40 characters", http.StatusBadRequest)
		return
	}
	path := filepath.Join(s.sessionsDir(), name+".json")

	switch r.Method {
	case http.MethodGet:
		data, err := os.ReadFile(path)
		if err != nil {
			http.Error(w, "no session "+name, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(data)

	case http.MethodPut, http.MethodPost:
		var doc json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&doc); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := os.MkdirAll(s.sessionsDir(), 0o755); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, doc, 0o644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if err := os.Rename(tmp, path); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]string{"saved": name})

	case http.MethodDelete:
		_ = os.Remove(path)
		s.chat.forget(name)
		writeJSON(w, map[string]string{"deleted": name})

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
