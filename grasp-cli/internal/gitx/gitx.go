// Package gitx wraps the git CLI. Every function takes the directory to run
// in, so the same helpers serve the main checkout and a PR worktree.
package gitx

import (
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// Run executes git with args in dir, returning trimmed stdout. Errors carry
// git's own stderr, which is usually the message worth showing the user.
func Run(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		if text == "" {
			text = err.Error()
		}
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), text)
	}
	return text, nil
}

func RepoRoot(dir string) (string, error) {
	return Run(dir, "rev-parse", "--show-toplevel")
}

func Head(dir string) (string, error) {
	return Run(dir, "rev-parse", "HEAD")
}

func Branch(dir string) (string, error) {
	return Run(dir, "rev-parse", "--abbrev-ref", "HEAD")
}

func MergeBase(dir, ref string) (string, error) {
	return Run(dir, "merge-base", "HEAD", ref)
}

func RefExists(dir, ref string) bool {
	_, err := Run(dir, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	return err == nil
}

// DefaultBaseBranch reads origin/HEAD ("main", "master", …); empty when unset.
func DefaultBaseBranch(dir string) string {
	out, err := Run(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(out, "origin/")
}

// ListFiles returns tracked plus untracked-but-not-ignored paths, relative to
// dir. This honors .gitignore, so generated bundles stay out of the index.
func ListFiles(dir string) ([]string, error) {
	out, err := Run(dir, "ls-files", "--cached", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	return strings.Split(out, "\n"), nil
}

// FileStatus classifies paths against a base commit: "A" added, "M" modified,
// "D" deleted. Untracked files come back as "A". Renames are disabled so a
// rename reads as delete + add.
func FileStatus(dir, base string) (map[string]string, error) {
	statuses := map[string]string{}
	out, err := Run(dir, "diff", "--name-status", "--no-renames", base)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			continue
		}
		statuses[parts[1]] = parts[0][:1]
	}
	untracked, err := Run(dir, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(untracked, "\n") {
		if line != "" {
			statuses[line] = "A"
		}
	}
	return statuses, nil
}

var hunkRe = regexp.MustCompile(`^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@`)

// ChangedLines returns the new-side line numbers a file's diff against base
// touches. A pure deletion (zero new lines) marks the two lines around the
// cut, so a function whose body lost lines still counts as modified.
func ChangedLines(dir, base, file string) (map[int]bool, error) {
	out, err := Run(dir, "diff", "-U0", base, "--", file)
	if err != nil {
		return nil, err
	}
	lines := map[int]bool{}
	for _, line := range strings.Split(out, "\n") {
		m := hunkRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		start, _ := strconv.Atoi(m[1])
		count := 1
		if m[2] != "" {
			count, _ = strconv.Atoi(m[2])
		}
		if count == 0 {
			lines[start] = true
			lines[start+1] = true
			continue
		}
		for i := 0; i < count; i++ {
			lines[start+i] = true
		}
	}
	return lines, nil
}

// ShowBlob reads a file's content at a commit.
func ShowBlob(dir, commit, file string) ([]byte, error) {
	cmd := exec.Command("git", "show", commit+":"+file)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git show %s:%s: %w", commit, file, err)
	}
	return out, nil
}

// IsWorktreeAt reports whether dir is itself a working tree root. Any
// directory under a checkout answers rev-parse (git resolves upward), so a
// stale non-worktree directory must never be handed to checkout — it would
// detach the parent checkout instead.
func IsWorktreeAt(dir string) bool {
	top, err := Run(dir, "rev-parse", "--show-toplevel")
	return err == nil && top == dir
}
