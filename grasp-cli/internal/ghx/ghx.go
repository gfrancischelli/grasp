// Package ghx wraps the GitHub CLI. gh has to be installed and signed in;
// origin has to be the remote the pull requests are on.
package ghx

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

type PR struct {
	Number      int    `json:"number"`
	Title       string `json:"title"`
	URL         string `json:"url"`
	BaseRefName string `json:"baseRefName"`
	HeadRefName string `json:"headRefName"`
	IsDraft     bool   `json:"isDraft"`
	UpdatedAt   string `json:"updatedAt"`
	Author      struct {
		Login string `json:"login"`
	} `json:"author"`
}

func run(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("gh", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("gh %s: %s", strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, fmt.Errorf("gh %s: %w", strings.Join(args, " "), err)
	}
	return out, nil
}

func View(dir string, number int) (*PR, error) {
	out, err := run(dir, "pr", "view", fmt.Sprint(number),
		"--json", "number,title,url,baseRefName,headRefName,author")
	if err != nil {
		return nil, err
	}
	var pr PR
	if err := json.Unmarshal(out, &pr); err != nil {
		return nil, fmt.Errorf("gh pr view did not answer with JSON: %w", err)
	}
	if pr.BaseRefName == "" || pr.HeadRefName == "" {
		return nil, fmt.Errorf("gh pr view %d did not name a base and a head branch", number)
	}
	return &pr, nil
}

func List(dir string) ([]PR, error) {
	out, err := run(dir, "pr", "list", "--limit", "100",
		"--json", "number,title,url,baseRefName,headRefName,author,isDraft,updatedAt")
	if err != nil {
		return nil, err
	}
	var prs []PR
	if err := json.Unmarshal(out, &prs); err != nil {
		return nil, fmt.Errorf("gh pr list did not answer with JSON: %w", err)
	}
	return prs, nil
}

func DefaultBranch(dir string) string {
	out, err := run(dir, "repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func Installed() bool {
	_, err := exec.LookPath("gh")
	return err == nil
}

func Authenticated() bool {
	return exec.Command("gh", "auth", "status").Run() == nil
}
