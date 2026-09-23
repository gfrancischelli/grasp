package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/config"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/indexer"
)

var indexBase string

var indexCmd = &cobra.Command{
	Use:   "index",
	Short: "Index the working tree against the base branch",
	Long: `Writes .grasp/index.json: every function with its source, span and call
sites, classified added/modified/unchanged/removed against the merge base of
HEAD and the base ref. Uncommitted and untracked work counts as part of the
branch, so the review reads the code as it is on disk.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}
		base, err := resolveBase(root, indexBase)
		if err != nil {
			return err
		}
		_, err = indexer.Build(indexer.Options{
			Root:    root,
			BaseRef: base,
			Log:     func(s string) { logln("%s", s) },
		})
		return err
	},
}

func init() {
	indexCmd.Flags().StringVar(&indexBase, "base", "", "ref to classify against (default: config, then origin/HEAD)")
	rootCmd.AddCommand(indexCmd)
}

// resolveBase picks the ref to review against: the flag, the repo config,
// then origin's default branch — preferring the origin/<name> remote ref so a
// stale local base branch does not skew the comparison.
func resolveBase(root, flag string) (string, error) {
	name := flag
	if name == "" {
		cfg, err := config.Load(root)
		if err != nil {
			return "", err
		}
		name = cfg.Review.Base
	}
	if name == "" {
		name = gitx.DefaultBaseBranch(root)
	}
	if name == "" {
		return "", fmt.Errorf("no base branch: pass --base, set review.base in .grasp/config.toml, or run grasp init")
	}
	for _, cand := range []string{"origin/" + name, name} {
		if gitx.RefExists(root, cand) {
			return cand, nil
		}
	}
	return "", fmt.Errorf("base ref %q not found (tried origin/%s and %s)", name, name, name)
}
