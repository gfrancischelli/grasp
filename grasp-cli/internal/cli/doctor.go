package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/agent"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/config"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/ghx"
)

var doctorPing bool

var doctorCmd = &cobra.Command{
	Use:   "doctor",
	Short: "Check the whole setup: git, gh, agent profile, index",
	Long: `Prints how every piece resolves — the repo, the base ref, gh auth, which
agent binary and profile a review would actually use — so a broken link in
the chain is visible instead of guessed at. --ping runs the agent once to
prove auth works (spends one small request).`,
	RunE: func(cmd *cobra.Command, args []string) error {
		failures := 0
		check := func(ok bool, label, detail string) {
			mark := "✓"
			if !ok {
				mark = "✗"
				failures++
			}
			if detail != "" {
				logln("%s %-14s %s", mark, label, detail)
			} else {
				logln("%s %s", mark, label)
			}
		}

		root, err := repoRoot()
		check(err == nil, "repo", root)
		if err != nil {
			return fmt.Errorf("%d problem(s)", failures)
		}

		cfg, cfgErr := config.Load(root)
		_, repoCfgErr := os.Stat(config.RepoPath(root))
		check(cfgErr == nil && repoCfgErr == nil, "config",
			configDetail(root, cfgErr, repoCfgErr))

		base, baseErr := resolveBase(root, "")
		check(baseErr == nil, "base", baseDetail(base, baseErr))

		check(ghx.Installed(), "gh", "installed")
		if ghx.Installed() {
			check(ghx.Authenticated(), "gh auth", "signed in")
		}

		agentPath, lookErr := exec.LookPath(cfg.Agent.Command)
		check(lookErr == nil, "agent", agentDetail(cfg, agentPath, lookErr))
		if cfg.Agent.ConfigDir != "" {
			dir := agent.ExpandPath(cfg.Agent.ConfigDir)
			info, statErr := os.Stat(dir)
			check(statErr == nil && info.IsDir(), "profile", dir)
		} else {
			logln("· %-14s %s", "profile", "claude default (no CLAUDE_CONFIG_DIR pinned)")
		}

		indexDetailStr, _ := indexDetail(root)
		logln("· %-14s %s", "index", indexDetailStr)

		if doctorPing && lookErr == nil {
			logln("pinging the agent (this spends one small request)…")
			reply, elapsed, pingErr := agent.Ping(cfg.Agent, 90*time.Second)
			check(pingErr == nil, "agent ping", fmt.Sprintf("%q in %s", reply, elapsed.Round(time.Millisecond)))
		}

		if failures > 0 {
			return fmt.Errorf("%d problem(s) found", failures)
		}
		logln("all good")
		return nil
	},
}

func init() {
	doctorCmd.Flags().BoolVar(&doctorPing, "ping", false, "run the agent once to prove auth works")
	rootCmd.AddCommand(doctorCmd)
}

func configDetail(root string, cfgErr, repoCfgErr error) string {
	if cfgErr != nil {
		return cfgErr.Error()
	}
	if repoCfgErr != nil {
		return "no .grasp/config.toml — run grasp init"
	}
	return config.RepoPath(root)
}

func baseDetail(base string, err error) string {
	if err != nil {
		return err.Error()
	}
	return base
}

func agentDetail(cfg config.Config, path string, err error) string {
	if err != nil {
		return fmt.Sprintf("%s not on PATH", cfg.Agent.Command)
	}
	if cfg.Agent.Model != "" {
		return fmt.Sprintf("%s (model %s)", path, cfg.Agent.Model)
	}
	return path
}

func indexDetail(root string) (string, bool) {
	path := filepath.Join(root, ".grasp", "index.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "none yet — run grasp index", false
	}
	var doc struct {
		GeneratedAt string            `json:"generated_at"`
		Functions   []json.RawMessage `json:"functions"`
		Git         struct {
			BaseRef string `json:"base_ref"`
		} `json:"git"`
	}
	if json.Unmarshal(data, &doc) != nil {
		return "unreadable — rerun grasp index", false
	}
	return fmt.Sprintf("%d functions against %s, generated %s",
		len(doc.Functions), doc.Git.BaseRef, doc.GeneratedAt), true
}
