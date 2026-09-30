// Package review puts a pull request's code in a worktree of its own and
// indexes it against its base — a port of upstream grasp's Grasp.PullRequest,
// minus the deps symlink and build seeding a tree-sitter indexer doesn't need.
package review

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/ghx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/indexer"
)

type Opened struct {
	PR       *ghx.PR
	Worktree string
	Index    *indexer.Index
}

func worktreePath(root string, number int) string {
	return filepath.Join(root, ".grasp", "worktrees", fmt.Sprintf("pr-%d", number))
}

func prRef(number int) string {
	return fmt.Sprintf("refs/grasp/pr-%d", number)
}

// Open fetches the pull request, checks its head out under
// .grasp/worktrees/pr-N (moving a worktree already there to the head just
// fetched), and builds the index inside it against the PR's base — written to
// the main checkout's .grasp/index.json, which the viewer watches.
//
// The checkout is not forced: an edit left uncommitted in the worktree stops
// with git's own message. Commit it, or Close to throw it away, and ask again.
func Open(root string, number int, baseOverride string, log func(string)) (*Opened, error) {
	pr, err := ghx.View(root, number)
	if err != nil {
		return nil, err
	}
	log(fmt.Sprintf("pull request %d: %s (%s against %s)", pr.Number, pr.Title, pr.HeadRefName, pr.BaseRefName))

	base := pr.BaseRefName
	if baseOverride != "" {
		base = baseOverride
	}

	log("fetching base and head")
	if _, err := gitx.Run(root, "fetch", "origin", base); err != nil {
		return nil, err
	}
	// pull/N/head works for forks too, where the head branch name would not.
	refspec := fmt.Sprintf("+refs/pull/%d/head:%s", number, prRef(number))
	if _, err := gitx.Run(root, "fetch", "origin", refspec); err != nil {
		return nil, err
	}

	wt := worktreePath(root, number)
	if _, err := os.Stat(wt); err == nil {
		// A directory git has forgotten — pruned while it was still there, or
		// copied into place — must not be handed to checkout: git resolves
		// upward, and `git -C stale-dir checkout` would detach the main
		// checkout instead.
		if !gitx.IsWorktreeAt(wt) {
			log(fmt.Sprintf("%s is not a worktree git knows; replacing it", wt))
			if err := os.RemoveAll(wt); err != nil {
				return nil, err
			}
			_, _ = gitx.Run(root, "worktree", "prune")
		}
	}
	if _, err := os.Stat(wt); err == nil {
		log("moving the worktree to the head just fetched")
		if _, err := gitx.Run(wt, "checkout", "--detach", prRef(number)); err != nil {
			return nil, fmt.Errorf("%w\n\ncommit what is in the worktree, or run `grasp pr %d --close` to throw it away", err, number)
		}
	} else {
		log("adding the worktree")
		if _, err := gitx.Run(root, "worktree", "add", "--detach", wt, prRef(number)); err != nil {
			return nil, err
		}
	}

	idx, err := indexer.Build(indexer.Options{
		Root:    wt,
		OutPath: filepath.Join(root, ".grasp", "index.json"),
		BaseRef: "origin/" + base,
		Review:  &indexer.Review{PR: pr.Number, Title: pr.Title, URL: pr.URL},
		Log:     log,
	})
	if err != nil {
		return nil, err
	}
	return &Opened{PR: pr, Worktree: wt, Index: idx}, nil
}

// Close removes the worktree and prunes the list. The removal is forced, so
// anything left uncommitted in it goes with it.
func Close(root string, number int) error {
	wt := worktreePath(root, number)
	if gitx.IsWorktreeAt(wt) {
		if _, err := gitx.Run(root, "worktree", "remove", "--force", wt); err != nil {
			return err
		}
	} else if _, err := os.Stat(wt); err == nil {
		if err := os.RemoveAll(wt); err != nil {
			return err
		}
	}
	_, _ = gitx.Run(root, "worktree", "prune")
	_, _ = gitx.Run(root, "update-ref", "-d", prRef(number))
	return nil
}

// OpenWorktrees lists the PR numbers with a worktree currently on disk.
func OpenWorktrees(root string) []int {
	entries, err := os.ReadDir(filepath.Join(root, ".grasp", "worktrees"))
	if err != nil {
		return nil
	}
	var numbers []int
	for _, e := range entries {
		var n int
		if _, err := fmt.Sscanf(e.Name(), "pr-%d", &n); err == nil && e.IsDir() {
			numbers = append(numbers, n)
		}
	}
	return numbers
}
