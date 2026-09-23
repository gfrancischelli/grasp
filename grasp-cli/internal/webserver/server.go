// Package webserver serves the embedded review canvas: a single page reading
// .grasp/index.json through a small local API, with comment threads persisted
// to .grasp/comments.json, reloading live when the index is rewritten — by
// `grasp index`, or by `grasp pr` pointing it at a worktree.
package webserver

import (
	"embed"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/comments"
)

//go:embed ui
var ui embed.FS

// AgentConfig names the coding-agent CLI the chat panel runs and the profile
// it runs under.
type AgentConfig struct {
	Command   string
	ConfigDir string
	Model     string
}

type Server struct {
	IndexPath string
	Port      int
	// AutoPort walks up from Port when it is taken — several grasps, one per
	// repo, coexist without anyone picking numbers. An explicit --port keeps
	// it off and fails loudly instead.
	AutoPort bool
	Editor   string // vscode | cursor | zed | idea | ""
	Author   string // comment author, from git config user.name
	Comments *comments.Store
	Agent    AgentConfig

	chat      *chatRunner
	bus       *eventBus
	idx       idxCache
	boundPort int
}

// eventBus fans canvas commands out to every connected viewer tab.
type eventBus struct {
	mu   sync.Mutex
	subs map[chan string]bool
}

func newEventBus() *eventBus { return &eventBus{subs: map[chan string]bool{}} }

func (b *eventBus) subscribe() chan string {
	ch := make(chan string, 16)
	b.mu.Lock()
	b.subs[ch] = true
	b.mu.Unlock()
	return ch
}

func (b *eventBus) unsubscribe(ch chan string) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

func (b *eventBus) publish(msg string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for ch := range b.subs {
		select {
		case ch <- msg:
			n++
		default: // a stalled tab drops the command rather than blocking the tool
		}
	}
	return n
}

// Run serves on 127.0.0.1 until the process is stopped. onReady is called
// with the URL once the listener is up — the place to open a browser from.
func (s *Server) Run(onReady func(url string)) error {
	s.chat = newChatRunner()
	s.bus = newEventBus()

	mux := http.NewServeMux()
	mux.HandleFunc("/mcp", s.handleMCP)
	mux.HandleFunc("/", s.page)
	mux.HandleFunc("/assets/", s.asset)
	mux.HandleFunc("/api/index", s.index)
	mux.HandleFunc("/api/config", s.config)
	mux.HandleFunc("/api/comments", s.comments)
	mux.HandleFunc("/api/publish", s.handlePublish)
	mux.HandleFunc("/api/review", s.handleReview)
	mux.HandleFunc("/api/sessions", s.sessions)
	mux.HandleFunc("/api/sessions/", s.sessions)
	mux.HandleFunc("/api/chat", s.handleChat)
	mux.HandleFunc("/api/chat/stop", s.handleChatStop)
	mux.HandleFunc("/api/chat/reset", s.handleChatReset)
	mux.HandleFunc("/events", s.events)

	var listener net.Listener
	var err error
	port := s.Port
	for {
		listener, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			break
		}
		if !s.AutoPort || port >= s.Port+30 {
			return fmt.Errorf("cannot listen on 127.0.0.1:%d: %w", port, err)
		}
		port++
	}
	if port != s.Port {
		fmt.Printf("port %d is taken (another grasp?) — serving on %d\n", s.Port, port)
	}
	s.boundPort = port
	if onReady != nil {
		onReady(fmt.Sprintf("http://127.0.0.1:%d", port))
	}
	return http.Serve(listener, loopbackOnly(mux))
}

// loopbackOnly refuses requests addressed to anything but localhost. Binding
// to 127.0.0.1 alone does not stop DNS rebinding — a domain resolving to
// 127.0.0.1 becomes same-origin with this server — so the Host header the
// request was addressed to is checked too.
func loopbackOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		switch strings.ToLower(host) {
		case "127.0.0.1", "localhost", "::1", "[::1]":
			next.ServeHTTP(w, r)
		default:
			http.Error(w, "grasp answers loopback requests only", http.StatusForbidden)
		}
	})
}

func (s *Server) page(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	data, err := ui.ReadFile("ui/index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(data)
}

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	// Parsing (cached by mtime) also re-anchors the comment threads, so the
	// page always fetches comments that already follow the new code.
	_, _, _, _ = s.loadIndex()
	data, err := os.ReadFile(s.IndexPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("no index at %s — run grasp index", s.IndexPath), http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

func (s *Server) asset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/assets/")
	if strings.Contains(name, "..") || strings.Contains(name, "/") {
		http.NotFound(w, r)
		return
	}
	data, err := ui.ReadFile("ui/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch {
	case strings.HasSuffix(name, ".css"):
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case strings.HasSuffix(name, ".js"):
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	}
	_, _ = w.Write(data)
}

func (s *Server) config(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{
		"editor": s.Editor,
		"author": s.Author,
		"agent":  map[string]string{"command": s.Agent.Command, "model": s.Agent.Model},
	})
}

// comments serves the thread store: GET the whole document, POST one action —
// {action: add|reply|resolve|unresolve|delete, …} — answering with the
// updated document.
func (s *Server) comments(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		doc, err := s.Comments.Load()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, doc)

	case http.MethodPost:
		var req struct {
			Action   string `json:"action"`
			Thread   string `json:"thread"`
			Function string `json:"function"`
			File     string `json:"file"`
			Line     int    `json:"line"`
			EndLine  int    `json:"end_line"`
			Side     string `json:"side"`
			Body     string `json:"body"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		author := s.Author
		if author == "" {
			author = "you"
		}
		var doc *comments.Doc
		var err error
		switch req.Action {
		case "add":
			if strings.TrimSpace(req.Body) == "" {
				http.Error(w, "empty comment", http.StatusBadRequest)
				return
			}
			anchor := s.anchorFor(req.Function, req.Line, req.Side)
			doc, err = s.Comments.AddThread(req.Function, req.File, req.Line, req.EndLine, req.Side, author, req.Body, anchor)
		case "reply":
			if strings.TrimSpace(req.Body) == "" {
				http.Error(w, "empty comment", http.StatusBadRequest)
				return
			}
			doc, err = s.Comments.Reply(req.Thread, author, req.Body)
		case "resolve":
			doc, err = s.Comments.SetResolved(req.Thread, true)
		case "unresolve":
			doc, err = s.Comments.SetResolved(req.Thread, false)
		case "delete":
			doc, err = s.Comments.Delete(req.Thread)
		default:
			http.Error(w, "unknown action "+req.Action, http.StatusBadRequest)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, doc)

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// events is a server-sent-events stream that says "reload" whenever the index
// file changes on disk, so the page redraws over the new code within a second.
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")

	last := s.mtime()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()
	commands := s.bus.subscribe()
	defer s.bus.unsubscribe(commands)

	fmt.Fprint(w, "event: hello\ndata: ok\n\n")
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case msg := <-commands:
			fmt.Fprintf(w, "event: canvas\ndata: %s\n\n", msg)
			flusher.Flush()
		case <-heartbeat.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		case <-ticker.C:
			if m := s.mtime(); m != last {
				last = m
				fmt.Fprint(w, "event: reload\ndata: index\n\n")
				flusher.Flush()
			}
		}
	}
}

func (s *Server) mtime() int64 {
	info, err := os.Stat(s.IndexPath)
	if err != nil {
		return 0
	}
	return info.ModTime().UnixNano()
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}
