// Package agent resolves which coding-agent CLI grasp drives and under which
// profile. Claude Code keeps one profile per CLAUDE_CONFIG_DIR; users with
// several (~/.claude, ~/.claude-work, …) get nondeterministic behavior when a
// tool spawns `claude` with inherited env — so the profile is chosen at init,
// stored in the repo config, and set explicitly on every spawn.
package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/config"
)

// Profiles lists candidate CLAUDE_CONFIG_DIR directories: ~/.claude plus any
// ~/.claude-* sibling. Empty string means "the CLI's own default".
func Profiles() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	matches, _ := filepath.Glob(filepath.Join(home, ".claude*"))
	var dirs []string
	for _, m := range matches {
		info, err := os.Stat(m)
		if err != nil || !info.IsDir() {
			continue
		}
		dirs = append(dirs, m)
	}
	return dirs
}

// Env returns the environment for spawning the agent, with the chosen profile
// pinned. The MCP server is passed inline per spawn (--mcp-config), never
// registered into a profile.
func Env(cfg config.Agent) []string {
	env := os.Environ()
	if cfg.ConfigDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+expand(cfg.ConfigDir))
	}
	return env
}

// Ping runs the configured agent with a trivial prompt to prove the whole
// chain — binary, profile, auth — actually answers.
func Ping(cfg config.Agent, timeout time.Duration) (string, time.Duration, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	args := []string{"-p", "reply with exactly: pong"}
	if cfg.Model != "" {
		args = append(args, "--model", cfg.Model)
	}
	cmd := exec.CommandContext(ctx, cfg.Command, args...)
	cmd.Env = Env(cfg)
	start := time.Now()
	out, err := cmd.CombinedOutput()
	elapsed := time.Since(start)
	reply := strings.TrimSpace(string(out))
	if i := strings.IndexByte(reply, '\n'); i > 0 {
		reply = reply[:i]
	}
	return reply, elapsed, err
}

func expand(path string) string {
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}

// ExpandPath is expand, exported for the CLI layer.
func ExpandPath(path string) string { return expand(path) }
