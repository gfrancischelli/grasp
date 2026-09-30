// Package cli wires the grasp commands. Every command runs from anywhere
// inside a repo; the repo root anchors config, index and worktrees.
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
)

// version is stamped by the Makefile via -ldflags at build time.
var version = "dev"

var rootCmd = &cobra.Command{
	Use:     "grasp",
	Short:   "Visual, language-agnostic code review from a standalone CLI",
	Version: version,
	Long: `grasp reviews a branch or a pull request on a canvas of function cards:
changed functions lead the sidebar, a modified card swaps between source and
diff, and call chains open left to right.

Standalone and language-agnostic: nothing is added to the project under
review beyond a gitignored .grasp/ directory.`,
	SilenceUsage:  true,
	SilenceErrors: true,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "grasp:", err)
		os.Exit(1)
	}
}

// repoRoot resolves the enclosing repo's root, refusing to run from inside a
// grasp worktree (reviews anchor to the checkout they were started from).
func repoRoot() (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	root, err := gitx.RepoRoot(cwd)
	if err != nil {
		return "", fmt.Errorf("not inside a git repository")
	}
	return root, nil
}

func logln(format string, args ...any) {
	fmt.Printf(format+"\n", args...)
}
