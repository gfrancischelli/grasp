package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	fuzzyfinder "github.com/ktr0731/go-fuzzyfinder"
	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/agent"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/config"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/ghx"
	"github.com/gfrancischelli/grasp/grasp-cli/internal/gitx"
)

var (
	initProfile string
	initEditor  string
	initYes     bool
	initForce   bool
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Set this repo up for grasp reviews",
	Long: `Detects the repo's languages, remote and base branch, asks which agent
profile to use, and writes:

  .grasp/config.toml   personal settings (gitignored)
  .grasp/review.md     the team's review rules (committable)

and the .gitignore entries for everything else under .grasp/.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}

		cfgPath := config.RepoPath(root)
		if _, err := os.Stat(cfgPath); err == nil && !initForce {
			return fmt.Errorf("%s already exists (use --force to rewrite it)", cfgPath)
		}

		languages := detectLanguages(root)
		if len(languages) == 0 {
			logln("warning: no Elixir, JS/TS or Go files found — the indexer speaks those")
		} else {
			logln("languages: %s", strings.Join(languages, ", "))
		}

		base := gitx.DefaultBaseBranch(root)
		if base == "" {
			base = ghx.DefaultBranch(root)
		}
		if base == "" {
			base = "main"
		}
		logln("base branch: %s", base)

		profile, err := chooseProfile()
		if err != nil {
			return err
		}
		if profile == "" {
			logln("agent profile: claude default")
		} else {
			logln("agent profile: %s", profile)
		}

		editor, err := chooseEditor()
		if err != nil {
			return err
		}
		if editor == "" {
			logln("editor: none (file:line stays plain text)")
		} else {
			logln("editor: %s (file:line deep links)", editor)
		}

		if err := os.MkdirAll(filepath.Join(root, ".grasp"), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(cfgPath, []byte(configTemplate(base, profile, editor, languages)), 0o644); err != nil {
			return err
		}
		logln("wrote %s", rel(root, cfgPath))

		reviewPath := filepath.Join(root, ".grasp", "review.md")
		if _, err := os.Stat(reviewPath); os.IsNotExist(err) {
			if err := os.WriteFile(reviewPath, []byte(reviewTemplate), 0o644); err != nil {
				return err
			}
			logln("wrote %s (committable — the team's review rules)", rel(root, reviewPath))
		}

		if added, err := ensureGitignore(root); err != nil {
			return err
		} else if added {
			logln("added .grasp/ to .gitignore (review.md stays tracked)")
		}

		logln("\nready. next:")
		logln("  grasp pr          review an open pull request")
		logln("  grasp web         review the current branch against %s", base)
		logln("  grasp doctor      check the whole setup")
		return nil
	},
}

func init() {
	initCmd.Flags().StringVar(&initProfile, "profile", "", "agent profile dir (CLAUDE_CONFIG_DIR); \"default\" for the CLI's own")
	initCmd.Flags().StringVar(&initEditor, "editor", "", "editor for file:line deep links (vscode|cursor|zed|idea|none)")
	initCmd.Flags().BoolVarP(&initYes, "yes", "y", false, "accept defaults, ask nothing")
	initCmd.Flags().BoolVar(&initForce, "force", false, "rewrite an existing .grasp/config.toml")
	rootCmd.AddCommand(initCmd)
}

func detectLanguages(root string) []string {
	paths, err := gitx.ListFiles(root)
	if err != nil {
		return nil
	}
	counts := map[string]int{}
	for _, p := range paths {
		if strings.Contains(p, "node_modules/") {
			continue
		}
		switch strings.ToLower(filepath.Ext(p)) {
		case ".ex", ".exs":
			counts["elixir"]++
		case ".ts", ".tsx", ".mts", ".cts":
			counts["typescript"]++
		case ".js", ".jsx", ".mjs", ".cjs":
			counts["javascript"]++
		case ".go":
			counts["go"]++
		}
	}
	var langs []string
	for _, l := range []string{"elixir", "typescript", "javascript", "go"} {
		if counts[l] > 0 {
			langs = append(langs, l)
		}
	}
	return langs
}

// chooseProfile picks the CLAUDE_CONFIG_DIR for this repo: the --profile flag,
// or an interactive pick over the ~/.claude* directories found. Empty string
// means the CLI's own default profile.
func chooseProfile() (string, error) {
	if initProfile == "default" {
		return "", nil
	}
	if initProfile != "" {
		p := agent.ExpandPath(initProfile)
		if info, err := os.Stat(p); err != nil || !info.IsDir() {
			return "", fmt.Errorf("--profile %s is not a directory", initProfile)
		}
		return initProfile, nil
	}

	profiles := agent.Profiles()
	if len(profiles) <= 1 || initYes || !term.IsTerminal(int(os.Stdin.Fd())) {
		return "", nil
	}

	options := append([]string{"claude default (no CLAUDE_CONFIG_DIR)"}, profiles...)
	i, err := fuzzyfinder.Find(options, func(i int) string { return options[i] },
		fuzzyfinder.WithHeader("Which Claude profile should reviews in this repo use?"))
	if err != nil {
		if err == fuzzyfinder.ErrAbort {
			return "", nil
		}
		return "", err
	}
	if i == 0 {
		return "", nil
	}
	// Store ~-relative so the config survives a home move.
	if home, herr := os.UserHomeDir(); herr == nil {
		if strings.HasPrefix(options[i], home+"/") {
			return "~/" + strings.TrimPrefix(options[i], home+"/"), nil
		}
	}
	return options[i], nil
}

// detectEditors lists the deep-linkable editors this machine has, by their
// CLI on PATH or their app bundle.
func detectEditors() []string {
	candidates := []struct {
		name string
		cli  string
		apps []string
	}{
		{"vscode", "code", []string{"/Applications/Visual Studio Code.app"}},
		{"cursor", "cursor", []string{"/Applications/Cursor.app"}},
		{"zed", "zed", []string{"/Applications/Zed.app"}},
		{"idea", "idea", []string{"/Applications/IntelliJ IDEA.app", "/Applications/IntelliJ IDEA CE.app"}},
	}
	var found []string
	for _, c := range candidates {
		if _, err := exec.LookPath(c.cli); err == nil {
			found = append(found, c.name)
			continue
		}
		for _, app := range c.apps {
			if st, err := os.Stat(app); err == nil && st.IsDir() {
				found = append(found, c.name)
				break
			}
		}
	}
	return found
}

// chooseEditor picks the editor file:line links open in: the --editor flag,
// the single editor detected, or an interactive pick when there are several.
// Empty means plain text.
func chooseEditor() (string, error) {
	valid := map[string]bool{"vscode": true, "cursor": true, "zed": true, "idea": true}
	if initEditor == "none" {
		return "", nil
	}
	if initEditor != "" {
		if !valid[initEditor] {
			return "", fmt.Errorf("--editor must be one of vscode, cursor, zed, idea or none")
		}
		return initEditor, nil
	}

	detected := detectEditors()
	if len(detected) == 0 {
		return "", nil
	}
	if len(detected) == 1 || initYes || !term.IsTerminal(int(os.Stdin.Fd())) {
		return detected[0], nil
	}

	options := append(detected, "none (plain file:line)")
	i, err := fuzzyfinder.Find(options, func(i int) string { return options[i] },
		fuzzyfinder.WithHeader("Which editor should file:line links open?"))
	if err != nil {
		if err == fuzzyfinder.ErrAbort {
			return detected[0], nil
		}
		return "", err
	}
	if i == len(options)-1 {
		return "", nil
	}
	return options[i], nil
}

func configTemplate(base, profile, editor string, languages []string) string {
	langs := make([]string, len(languages))
	for i, l := range languages {
		langs[i] = fmt.Sprintf("%q", l)
	}
	profileLine := "# config_dir = \"~/.claude\"     # pin a CLAUDE_CONFIG_DIR profile"
	if profile != "" {
		profileLine = fmt.Sprintf("config_dir = %q", profile)
	}
	editorLine := "# editor = \"vscode\"    # vscode | cursor | zed | idea — file:line deep links"
	if editor != "" {
		editorLine = fmt.Sprintf("editor = %q          # file:line deep links", editor)
	}
	return fmt.Sprintf(`# grasp — personal, per-repo settings (gitignored).
# Team review rules live in .grasp/review.md instead.

[agent]
backend = "claude-code"
command = "claude"
%s
# model = "opus"

[review]
base = %q
auto = true            # v2: run a review when the canvas opens (--no-review skips)

[index]
languages = [%s]

[web]
port = 4040
open = true
%s
`, profileLine, base, strings.Join(langs, ", "), editorLine)
}

const reviewTemplate = `# Review rules for this repo

These rules feed the automatic review grasp runs when a canvas opens (v2).
This file is committable on purpose: the team's standards travel with the
repo, while .grasp/config.toml stays personal and gitignored.

- Point out correctness bugs, not style — the linter owns style.
- Flag missing error handling on paths that can actually fail.
- Question new dependencies and copies of existing helpers.
`

func ensureGitignore(root string) (bool, error) {
	path := filepath.Join(root, ".gitignore")
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	if strings.Contains(string(data), ".grasp/") {
		return false, nil
	}
	entry := "\n# grasp\n.grasp/*\n!.grasp/review.md\n"
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return false, err
	}
	defer f.Close()
	if _, err := f.WriteString(entry); err != nil {
		return false, err
	}
	return true, nil
}

func rel(root, path string) string {
	if r, err := filepath.Rel(root, path); err == nil {
		return r
	}
	return path
}
