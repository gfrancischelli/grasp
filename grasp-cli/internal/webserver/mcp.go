package webserver

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/comments"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/indexer"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/publish"
)

// The MCP endpoint lets a coding agent read the same index the canvas draws
// and arrange the cards the reviewer is looking at. Served at /mcp on the
// viewer's port, loopback-only like everything else; the chat panel wires its
// agent to it automatically, and any MCP client can register it:
//
//	claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
//
// Canvas-arranging tools publish commands over the live-events stream; the
// browser tab reading that session applies them and autosaves. Reading tools
// answer from the index file directly.

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

func (s *Server) handleMCP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only (single-response streamable HTTP)", http.StatusMethodNotAllowed)
		return
	}
	var req rpcRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": err.Error()}})
		return
	}
	// notifications carry no id and expect no body
	if len(req.ID) == 0 || string(req.ID) == "null" {
		w.WriteHeader(http.StatusAccepted)
		return
	}

	reply := func(result any) {
		writeJSON(w, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
	}
	replyErr := func(code int, msg string) {
		writeJSON(w, map[string]any{"jsonrpc": "2.0", "id": req.ID, "error": map[string]any{"code": code, "message": msg}})
	}

	switch req.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(req.Params, &p)
		if p.ProtocolVersion == "" {
			p.ProtocolVersion = "2024-11-05"
		}
		reply(map[string]any{
			"protocolVersion": p.ProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "grasp", "version": "0.2"},
		})
	case "ping":
		reply(map[string]any{})
	case "tools/list":
		reply(map[string]any{"tools": mcpTools})
	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			replyErr(-32602, err.Error())
			return
		}
		result, err := s.callTool(p.Name, p.Arguments)
		if err != nil {
			reply(map[string]any{"isError": true, "content": []map[string]any{{"type": "text", "text": err.Error()}}})
			return
		}
		text, _ := json.MarshalIndent(result, "", " ")
		reply(map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}})
	default:
		replyErr(-32601, "method not found: "+req.Method)
	}
}

// --- tool definitions ---

func schema(props map[string]any, required ...string) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": props, "required": required}
}

func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

func strArr(desc string) map[string]any {
	return map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": desc}
}
func num(desc string) map[string]any   { return map[string]any{"type": "integer", "description": desc} }
func boolp(desc string) map[string]any { return map[string]any{"type": "boolean", "description": desc} }

var mcpTools = []map[string]any{
	{"name": "list_changes", "description": "Every function the branch added, modified or removed, with the base ref it was compared against. The first call of a pull-request review.", "inputSchema": schema(map[string]any{})},
	{"name": "search_functions", "description": "Find functions by name or id. An exact id ranks first, then ids containing the query.", "inputSchema": schema(map[string]any{"query": str("name, module or id fragment")}, "query")},
	{"name": "get_function", "description": "One function's source, span, calls, callers, and the open review comments on its lines.", "inputSchema": schema(map[string]any{"id": str("function id, e.g. Mod.fun/2")}, "id")},
	{"name": "get_callers", "description": "Who calls this function (one hop up the call graph).", "inputSchema": schema(map[string]any{"id": str("function id")}, "id")},
	{"name": "get_callees", "description": "What this function calls (one hop down).", "inputSchema": schema(map[string]any{"id": str("function id")}, "id")},
	{"name": "find_paths", "description": "Shortest call paths down to a function — from another function, or with no `from`, from the no-caller functions that reach it.", "inputSchema": schema(map[string]any{"to": str("target function id"), "from": str("optional source function id")}, "to")},
	{"name": "list_modules", "description": "The indexed modules with their files.", "inputSchema": schema(map[string]any{})},
	{"name": "list_entry_points", "description": "Functions nothing in the project calls — approximate entry points (framework route/worker detection is not implemented yet).", "inputSchema": schema(map[string]any{})},
	{"name": "reload_index", "description": "Re-read the index file and report what it holds now: functions, changes, git refs.", "inputSchema": schema(map[string]any{})},
	{"name": "list_sessions", "description": "The saved review sessions.", "inputSchema": schema(map[string]any{})},
	{"name": "get_session", "description": "A session's open cards, views and edges. Cards autosave moments after the canvas changes, so this reads the state as of about a second ago.", "inputSchema": schema(map[string]any{"session": str("session name; omit for the review's default")})},
	{"name": "set_cards", "description": "Replace the whole canvas with a graph described in one call and lay it out. Each card is {key, function_id, parent_key?, group?}; a card hangs under an earlier one by naming its key; two entries naming the same function are one card with an edge from each parent. group is a title: cards sharing one are framed together; a card that names no group takes its parent's.", "inputSchema": schema(map[string]any{
		"cards": map[string]any{"type": "array", "description": "cards in placement order", "items": schema(map[string]any{
			"key": str("your handle for this card"), "function_id": str("indexed function id"), "parent_key": str("optional key of the calling card"), "group": str("optional frame title"),
		}, "key", "function_id")},
		"session": str("session name; omit for the review's default"),
	}, "cards")},
	{"name": "group_cards", "description": "Frame cards already open under a title, joining the group already carrying it. A card belongs to one group, so naming it here takes it out of the one it was in.", "inputSchema": schema(map[string]any{
		"function_ids": strArr("open cards to frame"), "title": str("frame title; empty for an untitled frame"), "session": str("optional session"),
	}, "function_ids")},
	{"name": "ungroup_cards", "description": "Take cards out of their groups, back to the unframed canvas.", "inputSchema": schema(map[string]any{
		"function_ids": strArr("cards to unframe"), "session": str("optional session"),
	}, "function_ids")},
	{"name": "rename_group", "description": "Give a group another title (or none), keeping its cards.", "inputSchema": schema(map[string]any{
		"group": str("the group's current title"), "title": str("the new title; empty clears it"), "session": str("optional session"),
	}, "group")},
	{"name": "open_card", "description": "Add one card to the canvas, beside its caller when called_by names one.", "inputSchema": schema(map[string]any{"function_id": str("function to open"), "called_by": str("optional function id already on canvas"), "session": str("optional session")}, "function_id")},
	{"name": "close_card", "description": "Close one card and the edges touching it.", "inputSchema": schema(map[string]any{"function_id": str("function to close"), "session": str("optional session")}, "function_id")},
	{"name": "focus_card", "description": "Scroll a card into view, to say \"look here\".", "inputSchema": schema(map[string]any{"function_id": str("function to focus"), "session": str("optional session")}, "function_id")},
	{"name": "set_view", "description": "Show a card as source or as its diff against the base (modified functions only have a diff).", "inputSchema": schema(map[string]any{"function_id": str("function"), "view": str("source | diff"), "session": str("optional session")}, "function_id", "view")},
	{"name": "highlight_card", "description": "Point at a line (or range) inside an open card: pans there and tints it briefly.", "inputSchema": schema(map[string]any{"function_id": str("function"), "line": num("line number (new side, absolute)"), "end_line": num("optional range end"), "session": str("optional session")}, "function_id", "line")},
	{"name": "list_comments", "description": "The review threads with their replies. Open threads only unless include_resolved.", "inputSchema": schema(map[string]any{"include_resolved": boolp("include resolved threads")})},
	{"name": "add_comment", "description": "Write a comment on a line (or a range) as the agent. side=new is the branch's code; side=base with a function-relative line lands on a modified function's base version.", "inputSchema": schema(map[string]any{
		"function": str("function id"), "file": str("file path from the index"), "line": num("line (new side: absolute; base side: within base_source)"),
		"end_line": num("optional range end"), "side": str("new | base (default new)"), "body": str("the comment"),
	}, "function", "file", "line", "body")},
	{"name": "reply_comment", "description": "Answer a thread, as the agent.", "inputSchema": schema(map[string]any{"thread": str("thread id"), "body": str("the reply")}, "thread", "body")},
	{"name": "resolve_comment", "description": "Close a thread once it is dealt with, or reopen one.", "inputSchema": schema(map[string]any{"thread": str("thread id"), "reopen": boolp("reopen instead of resolving")}, "thread")},
	{"name": "publish_comments", "description": "Post the threads to the pull request as review comments, each with its replies. Already-published threads are skipped.", "inputSchema": schema(map[string]any{"pr": num("PR number; omit for the one under review")})},
}

// --- index cache + call graph ---

type callerRef struct {
	From  string        `json:"from"`
	Range indexer.Range `json:"range"`
}

type idxCache struct {
	mu      sync.Mutex
	mtime   int64
	idx     *indexer.Index
	byID    map[string]*indexer.Function
	callers map[string][]callerRef
}

func (s *Server) loadIndex() (*indexer.Index, map[string]*indexer.Function, map[string][]callerRef, error) {
	s.idx.mu.Lock()
	defer s.idx.mu.Unlock()
	m := s.mtime()
	if s.idx.idx == nil || m != s.idx.mtime {
		data, err := os.ReadFile(s.IndexPath)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("no index at %s — run grasp index", s.IndexPath)
		}
		var idx indexer.Index
		if err := json.Unmarshal(data, &idx); err != nil {
			return nil, nil, nil, err
		}
		byID := map[string]*indexer.Function{}
		callers := map[string][]callerRef{}
		for _, f := range idx.Functions {
			byID[f.ID] = f
		}
		for _, f := range idx.Functions {
			for _, c := range f.Calls {
				callers[c.Target] = append(callers[c.Target], callerRef{From: f.ID, Range: c.Range})
			}
		}
		s.idx.mtime, s.idx.idx, s.idx.byID, s.idx.callers = m, &idx, byID, callers
		// The code under the threads may have moved: follow the anchors.
		s.reanchorAll(byID)
	}
	return s.idx.idx, s.idx.byID, s.idx.callers, nil
}

func (s *Server) defaultSession() string {
	idx, _, _, err := s.loadIndex()
	if err == nil && idx.Review != nil && idx.Review.PR > 0 {
		return fmt.Sprintf("pr-%d", idx.Review.PR)
	}
	return "default"
}

// --- dispatch ---

func argStr(args map[string]any, key string) string {
	v, _ := args[key].(string)
	return v
}

func argInt(args map[string]any, key string) int {
	if v, ok := args[key].(float64); ok {
		return int(v)
	}
	return 0
}

func fnSummary(f *indexer.Function) map[string]any {
	return map[string]any{
		"id": f.ID, "module": f.Module, "name": f.Name, "arity": f.Arity, "kind": f.Kind,
		"file": f.File, "span": f.Span, "change": f.Change,
	}
}

func (s *Server) callTool(name string, args map[string]any) (any, error) {
	if args == nil {
		args = map[string]any{}
	}
	session := argStr(args, "session")
	if session == "" {
		session = s.defaultSession()
	}

	switch name {
	case "list_changes":
		idx, _, _, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		var out []map[string]any
		for _, f := range idx.Functions {
			if f.Change != "unchanged" {
				out = append(out, fnSummary(f))
			}
		}
		return map[string]any{"base_ref": idx.Git.BaseRef, "review": idx.Review, "changes": out}, nil

	case "search_functions":
		idx, byID, _, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		q := strings.ToLower(argStr(args, "query"))
		if q == "" {
			return nil, fmt.Errorf("query is required")
		}
		type hit struct {
			rank int
			f    *indexer.Function
		}
		var hits []hit
		if f, ok := byID[argStr(args, "query")]; ok {
			hits = append(hits, hit{0, f})
		}
		for _, f := range idx.Functions {
			lid := strings.ToLower(f.ID)
			switch {
			case lid == q:
				hits = append(hits, hit{0, f})
			case strings.Contains(strings.ToLower(f.Name), q):
				hits = append(hits, hit{1, f})
			case strings.Contains(lid, q):
				hits = append(hits, hit{2, f})
			}
		}
		sort.SliceStable(hits, func(i, j int) bool { return hits[i].rank < hits[j].rank })
		var out []map[string]any
		seen := map[string]bool{}
		for _, h := range hits {
			if seen[h.f.ID] {
				continue
			}
			seen[h.f.ID] = true
			out = append(out, fnSummary(h.f))
			if len(out) == 20 {
				break
			}
		}
		return map[string]any{"matches": out}, nil

	case "get_function":
		_, byID, callers, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		f, ok := byID[argStr(args, "id")]
		if !ok {
			return nil, fmt.Errorf("no function %s in the index", argStr(args, "id"))
		}
		doc, _ := s.Comments.Load()
		open := []*comments.Thread{}
		for _, t := range doc.Threads {
			if t.Function == f.ID && !t.Resolved {
				open = append(open, t)
			}
		}
		callerList := callers[f.ID]
		if callerList == nil {
			callerList = []callerRef{}
		}
		return map[string]any{
			"function": f, "callers": callerList, "comments": open,
		}, nil

	case "get_callers":
		_, byID, callers, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		id := argStr(args, "id")
		if _, ok := byID[id]; !ok {
			return nil, fmt.Errorf("no function %s in the index", id)
		}
		var out []map[string]any
		for _, c := range callers[id] {
			if f := byID[c.From]; f != nil {
				m := fnSummary(f)
				m["call_at"] = c.Range
				out = append(out, m)
			}
		}
		return map[string]any{"callers": out}, nil

	case "get_callees":
		_, byID, _, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		f, ok := byID[argStr(args, "id")]
		if !ok {
			return nil, fmt.Errorf("no function %s in the index", argStr(args, "id"))
		}
		var out []map[string]any
		for _, c := range f.Calls {
			if t := byID[c.Target]; t != nil {
				m := fnSummary(t)
				m["call_at"] = c.Range
				out = append(out, m)
			}
		}
		return map[string]any{"callees": out}, nil

	case "find_paths":
		return s.findPaths(argStr(args, "to"), argStr(args, "from"))

	case "list_modules":
		idx, _, _, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		return map[string]any{"modules": idx.Modules}, nil

	case "list_entry_points":
		idx, _, callers, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		var out []map[string]any
		for _, f := range idx.Functions {
			if len(callers[f.ID]) == 0 && !f.Removed {
				out = append(out, fnSummary(f))
			}
		}
		return map[string]any{"note": "functions with no caller in the index — approximate entry points", "entry_points": out}, nil

	case "reload_index":
		s.idx.mu.Lock()
		s.idx.mtime = 0 // force reparse
		s.idx.mu.Unlock()
		idx, _, _, err := s.loadIndex()
		if err != nil {
			return nil, err
		}
		changed := 0
		for _, f := range idx.Functions {
			if f.Change != "unchanged" {
				changed++
			}
		}
		return map[string]any{"path": s.IndexPath, "functions": len(idx.Functions), "changed": changed, "git": idx.Git, "review": idx.Review}, nil

	case "list_sessions":
		entries, _ := os.ReadDir(s.sessionsDir())
		names := []string{}
		for _, e := range entries {
			if n, ok := strings.CutSuffix(e.Name(), ".json"); ok {
				names = append(names, n)
			}
		}
		return map[string]any{"sessions": names, "default": s.defaultSession()}, nil

	case "get_session":
		data, err := os.ReadFile(filepath.Join(s.sessionsDir(), session+".json"))
		if err != nil {
			return map[string]any{"session": session, "cards": []any{}, "note": "no saved state yet"}, nil
		}
		var doc any
		_ = json.Unmarshal(data, &doc)
		return map[string]any{"session": session, "state": doc}, nil

	case "set_cards", "open_card", "close_card", "focus_card", "set_view", "highlight_card",
		"group_cards", "ungroup_cards", "rename_group":
		return s.canvasCommand(name, args, session)

	case "list_comments":
		doc, err := s.Comments.Load()
		if err != nil {
			return nil, err
		}
		include := args["include_resolved"] == true
		var out []*comments.Thread
		for _, t := range doc.Threads {
			if include || !t.Resolved {
				out = append(out, t)
			}
		}
		return map[string]any{"threads": out}, nil

	case "add_comment":
		side := argStr(args, "side")
		anchor := s.anchorFor(argStr(args, "function"), argInt(args, "line"), side)
		doc, err := s.Comments.AddThread(argStr(args, "function"), argStr(args, "file"),
			argInt(args, "line"), argInt(args, "end_line"), side, "agent", argStr(args, "body"), anchor)
		if err != nil {
			return nil, err
		}
		s.bus.publish(`{"op":"comments_changed"}`)
		return map[string]any{"thread": doc.Threads[len(doc.Threads)-1].ID}, nil

	case "reply_comment":
		_, err := s.Comments.Reply(argStr(args, "thread"), "agent", argStr(args, "body"))
		if err != nil {
			return nil, err
		}
		s.bus.publish(`{"op":"comments_changed"}`)
		return map[string]any{"ok": true}, nil

	case "resolve_comment":
		_, err := s.Comments.SetResolved(argStr(args, "thread"), args["reopen"] != true)
		if err != nil {
			return nil, err
		}
		s.bus.publish(`{"op":"comments_changed"}`)
		return map[string]any{"ok": true}, nil

	case "publish_comments":
		root := filepath.Dir(filepath.Dir(s.Comments.Path))
		number := argInt(args, "pr")
		if number == 0 {
			idx, _, _, err := s.loadIndex()
			if err == nil && idx.Review != nil {
				number = idx.Review.PR
			}
		}
		if number == 0 {
			var err error
			if number, err = publish.CurrentPR(root); err != nil {
				return nil, err
			}
		}
		var lines []string
		sum, err := publish.Run(root, number, func(l string) { lines = append(lines, l) })
		if err != nil {
			return nil, err
		}
		s.bus.publish(`{"op":"comments_changed"}`)
		return map[string]any{"published": sum.Published, "skipped": sum.Skipped, "failed": sum.Failed, "log": lines}, nil
	}
	return nil, fmt.Errorf("unknown tool %s", name)
}

// canvasCommand validates against the index and hands the command to the
// browser tab reading the session, which applies it and autosaves.
func (s *Server) canvasCommand(op string, args map[string]any, session string) (any, error) {
	_, byID, _, err := s.loadIndex()
	if err != nil {
		return nil, err
	}
	checkFn := func(id string) error {
		if _, ok := byID[id]; !ok {
			return fmt.Errorf("no function %s in the index", id)
		}
		return nil
	}
	cmd := map[string]any{"op": op, "session": session}
	switch op {
	case "set_cards":
		cards, _ := args["cards"].([]any)
		if len(cards) == 0 {
			return nil, fmt.Errorf("cards is required and must be non-empty")
		}
		for _, c := range cards {
			m, _ := c.(map[string]any)
			if m == nil || argStr(m, "key") == "" {
				return nil, fmt.Errorf("every card needs a key and a function_id")
			}
			if err := checkFn(argStr(m, "function_id")); err != nil {
				return nil, err
			}
		}
		cmd["cards"] = cards
	case "open_card", "close_card", "focus_card":
		if err := checkFn(argStr(args, "function_id")); err != nil && op != "close_card" {
			return nil, err
		}
		cmd["function_id"] = argStr(args, "function_id")
		if cb := argStr(args, "called_by"); cb != "" {
			cmd["called_by"] = cb
		}
	case "set_view":
		if err := checkFn(argStr(args, "function_id")); err != nil {
			return nil, err
		}
		v := argStr(args, "view")
		if v != "source" && v != "diff" {
			return nil, fmt.Errorf("view must be source or diff")
		}
		cmd["function_id"] = argStr(args, "function_id")
		cmd["view"] = v
	case "highlight_card":
		if err := checkFn(argStr(args, "function_id")); err != nil {
			return nil, err
		}
		cmd["function_id"] = argStr(args, "function_id")
		cmd["line"] = argInt(args, "line")
		if e := argInt(args, "end_line"); e > 0 {
			cmd["end_line"] = e
		}
	case "group_cards", "ungroup_cards":
		ids, _ := args["function_ids"].([]any)
		if len(ids) == 0 {
			return nil, fmt.Errorf("function_ids is required and must be non-empty")
		}
		cmd["function_ids"] = ids
		cmd["title"] = argStr(args, "title")
	case "rename_group":
		cmd["group"] = argStr(args, "group")
		cmd["title"] = argStr(args, "title")
	}
	data, _ := json.Marshal(cmd)
	n := s.bus.publish(string(data))
	if n == 0 {
		return nil, fmt.Errorf("no viewer tab is connected — open the canvas in the browser first")
	}
	return map[string]any{"delivered_to": n, "session": session}, nil
}

// findPaths walks the call graph backwards from `to`, up to `from` or up to
// the no-caller functions that reach it, and returns the shortest paths in
// call order.
func (s *Server) findPaths(to, from string) (any, error) {
	_, byID, callers, err := s.loadIndex()
	if err != nil {
		return nil, err
	}
	if _, ok := byID[to]; !ok {
		return nil, fmt.Errorf("no function %s in the index", to)
	}
	parent := map[string]string{to: ""}
	queue := []string{to}
	var starts []string
	for len(queue) > 0 && len(starts) < 6 {
		n := queue[0]
		queue = queue[1:]
		callersOf := callers[n]
		if from != "" {
			if n == from {
				starts = append(starts, n)
				continue
			}
		} else if len(callersOf) == 0 && n != to {
			starts = append(starts, n)
			continue
		}
		for _, c := range callersOf {
			if _, seen := parent[c.From]; !seen {
				parent[c.From] = n
				queue = append(queue, c.From)
			}
		}
	}
	var paths [][]string
	for _, start := range starts {
		var path []string
		for n := start; n != ""; n = parent[n] {
			path = append(path, n)
		}
		paths = append(paths, path)
	}
	if from != "" && len(paths) == 0 {
		return map[string]any{"paths": paths, "note": fmt.Sprintf("no call path from %s down to %s", from, to)}, nil
	}
	return map[string]any{"paths": paths}, nil
}
