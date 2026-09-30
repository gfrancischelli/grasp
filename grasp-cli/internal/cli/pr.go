package cli

import (
	"fmt"
	"os"
	"strconv"

	fuzzyfinder "github.com/ktr0731/go-fuzzyfinder"
	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/ghx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/review"
)

var (
	prClose bool
	prBase  string
)

var prCmd = &cobra.Command{
	Use:   "pr [number]",
	Short: "Open a pull request for review in a worktree of its own",
	Long: `Checks the pull request's head out under .grasp/worktrees/pr-N and indexes
it against the PR's base, leaving your own checkout on the branch it was on.
Without a number, picks from the repo's open pull requests.

Comments and sessions stay under this checkout, so a review outlives the
worktree it was written against. --close removes the worktree again; the
removal is forced, so anything uncommitted in it goes too.`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}

		number := 0
		if len(args) == 1 {
			number, err = strconv.Atoi(args[0])
			if err != nil || number <= 0 {
				return fmt.Errorf("%s is not a pull request number", args[0])
			}
		}

		if prClose {
			if number == 0 {
				number, err = pickWorktree(root)
				if err != nil {
					return err
				}
			}
			if err := review.Close(root, number); err != nil {
				return err
			}
			logln("closed the worktree for pull request %d", number)
			return nil
		}

		if number == 0 {
			number, err = pickPR(root)
			if err != nil {
				return err
			}
		}

		opened, err := review.Open(root, number, prBase, func(s string) { logln("%s", s) })
		if err != nil {
			return err
		}
		logln("\npull request %d is ready: %s (%s against %s) — %s",
			opened.PR.Number, opened.PR.Title, opened.PR.HeadRefName, opened.PR.BaseRefName, opened.PR.URL)
		logln("open the viewer with `grasp web` (it keeps this pull request's index)")
		return nil
	},
}

func init() {
	prCmd.Flags().BoolVar(&prClose, "close", false, "remove the pull request's worktree")
	prCmd.Flags().StringVar(&prBase, "base", "", "review against this ref instead of the PR's base branch")
	rootCmd.AddCommand(prCmd)
}

func pickPR(root string) (int, error) {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return 0, fmt.Errorf("no pull request number given and stdin is not a terminal")
	}
	prs, err := ghx.List(root)
	if err != nil {
		return 0, err
	}
	if len(prs) == 0 {
		return 0, fmt.Errorf("no open pull requests on this repo")
	}
	i, err := fuzzyfinder.Find(prs, func(i int) string {
		draft := ""
		if prs[i].IsDraft {
			draft = " [draft]"
		}
		return fmt.Sprintf("#%d %s%s", prs[i].Number, prs[i].Title, draft)
	},
		fuzzyfinder.WithHeader("Which pull request?"),
		fuzzyfinder.WithPreviewWindow(func(i, w, h int) string {
			if i < 0 {
				return ""
			}
			p := prs[i]
			return fmt.Sprintf("#%d %s\n\nauthor:  %s\nbranch:  %s → %s\nupdated: %s\n%s",
				p.Number, p.Title, p.Author.Login, p.HeadRefName, p.BaseRefName, p.UpdatedAt, p.URL)
		}))
	if err != nil {
		if err == fuzzyfinder.ErrAbort {
			return 0, fmt.Errorf("cancelled")
		}
		return 0, err
	}
	return prs[i].Number, nil
}

func pickWorktree(root string) (int, error) {
	numbers := review.OpenWorktrees(root)
	if len(numbers) == 0 {
		return 0, fmt.Errorf("no pull request worktrees under .grasp/worktrees/")
	}
	if len(numbers) == 1 {
		return numbers[0], nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return 0, fmt.Errorf("several worktrees open (%v); name one: grasp pr --close N", numbers)
	}
	i, err := fuzzyfinder.Find(numbers, func(i int) string {
		return fmt.Sprintf("pr-%d", numbers[i])
	}, fuzzyfinder.WithHeader("Close which worktree?"))
	if err != nil {
		return 0, fmt.Errorf("cancelled")
	}
	return numbers[i], nil
}
