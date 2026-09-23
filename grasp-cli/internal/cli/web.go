package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/comments"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/config"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/indexer"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/webserver"
)

var (
	webBase    string
	webPort    int
	webNoOpen  bool
	webNoIndex bool
	webReindex bool
	webWatch   bool
)

var webCmd = &cobra.Command{
	Use:   "web",
	Short: "Index the current branch and serve the review canvas",
	Long: `Indexes the working tree against the base branch and serves the embedded
viewer on 127.0.0.1, opening the browser unless --no-open. The canvas redraws
live whenever .grasp/index.json is rewritten — by grasp index, or by grasp pr
pointing it at a pull request's worktree (use --no-index then, so the PR's
index is served untouched).

Comment threads land in .grasp/comments.json under this checkout and survive
a worktree's --close; grasp publish sends them to the pull request.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}
		cfg, err := config.Load(root)
		if err != nil {
			return err
		}

		indexPath := filepath.Join(root, ".grasp", "index.json")

		// A plain `grasp web` after `grasp pr` must not reindex the branch
		// over the pull request's index — keep it while its worktree lives,
		// unless --reindex says otherwise.
		if pr, alive := prIndexAlive(indexPath); pr > 0 && alive && !webReindex && !webNoIndex {
			logln("serving pull request %d's index (its worktree is still open)", pr)
			logln("  grasp pr %d --close   to finish that review, or", pr)
			logln("  grasp web --reindex   to review the current branch instead")
			webNoIndex = true
		}

		if !webNoIndex {
			base, err := resolveBase(root, webBase)
			if err != nil {
				return err
			}
			if _, err := indexer.Build(indexer.Options{
				Root:    root,
				BaseRef: base,
				Log:     func(s string) { logln("%s", s) },
			}); err != nil {
				return err
			}
		}
		if _, err := os.Stat(indexPath); err != nil {
			return fmt.Errorf("no index at %s — run grasp index first", indexPath)
		}

		port := cfg.Web.Port
		if webPort != 0 {
			port = webPort
		}
		author, _ := gitx.Run(root, "config", "user.name")

		// --watch reindexes whenever HEAD or the working tree changes — a
		// pull, a push, a commit, an edit — and the canvas live-reloads with
		// threads re-anchored. It watches the branch, so it stays off while a
		// PR's index is being served.
		if webWatch {
			if webNoIndex {
				logln("--watch is off: the index on disk is being served as-is")
			} else {
				base, err := resolveBase(root, webBase)
				if err != nil {
					return err
				}
				go watchAndReindex(root, base)
			}
		}

		server := &webserver.Server{
			IndexPath: indexPath,
			Port:      port,
			AutoPort:  !cmd.Flags().Changed("port"),
			Editor:    cfg.Web.Editor,
			Author:    author,
			Comments:  comments.NewStore(root),
			Agent: webserver.AgentConfig{
				Command:   cfg.Agent.Command,
				ConfigDir: cfg.Agent.ConfigDir,
				Model:     cfg.Agent.Model,
			},
		}
		return server.Run(func(url string) {
			logln("grasp: %s  (index: %s)", url, indexPath)
			if cfg.Web.Open && !webNoOpen {
				_ = exec.Command("open", url).Start()
			}
		})
	},
}

func init() {
	webCmd.Flags().StringVar(&webBase, "base", "", "ref to review against (default: config, then origin/HEAD)")
	webCmd.Flags().IntVar(&webPort, "port", 0, "viewer port (default: config, then 4040)")
	webCmd.Flags().BoolVar(&webNoOpen, "no-open", false, "do not open the browser")
	webCmd.Flags().BoolVar(&webNoIndex, "no-index", false, "serve the index already on disk without reindexing")
	webCmd.Flags().BoolVar(&webReindex, "reindex", false, "reindex the current branch even over a PR's index")
	webCmd.Flags().BoolVar(&webWatch, "watch", false, "reindex whenever HEAD or the working tree changes")
	rootCmd.AddCommand(webCmd)
}

// watchAndReindex polls the repo's state — HEAD plus the porcelain status —
// every two seconds and rebuilds the index when it changes. The viewer picks
// the rewrite up over its live-events stream; nothing else to wire.
func watchAndReindex(root, base string) {
	state := func() string {
		head, _ := gitx.Run(root, "rev-parse", "HEAD")
		dirty, _ := gitx.Run(root, "status", "--porcelain")
		return head + "\n" + dirty
	}
	last := state()
	for {
		time.Sleep(2 * time.Second)
		cur := state()
		if cur == last {
			continue
		}
		last = cur
		if _, err := indexer.Build(indexer.Options{
			Root:    root,
			BaseRef: base,
			Log:     func(string) {},
		}); err != nil {
			logln("watch: reindex failed: %v", err)
		} else {
			logln("watch: the tree changed — reindexed")
		}
	}
}

// prIndexAlive reports whether the index on disk reviews a pull request whose
// worktree still exists.
func prIndexAlive(indexPath string) (int, bool) {
	data, err := os.ReadFile(indexPath)
	if err != nil {
		return 0, false
	}
	var idx struct {
		Project struct {
			Root string `json:"root"`
		} `json:"project"`
		Review *struct {
			PR int `json:"pr"`
		} `json:"review"`
	}
	if json.Unmarshal(data, &idx) != nil || idx.Review == nil || idx.Review.PR <= 0 {
		return 0, false
	}
	st, err := os.Stat(idx.Project.Root)
	return idx.Review.PR, err == nil && st.IsDir()
}
