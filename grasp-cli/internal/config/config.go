// Package config layers grasp's settings: built-in defaults, then the user's
// global ~/.config/grasp/config.toml, then the repo's .grasp/config.toml.
//
// The repo config is personal (it names profile paths on this machine) and is
// gitignored; the team-shared review rules live in .grasp/review.md instead.
package config

import (
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Agent  Agent  `toml:"agent"`
	Review Review `toml:"review"`
	Index  Index  `toml:"index"`
	Web    Web    `toml:"web"`
}

type Agent struct {
	Backend   string `toml:"backend"`
	Command   string `toml:"command"`
	ConfigDir string `toml:"config_dir"`
	Model     string `toml:"model"`
}

type Review struct {
	Base string `toml:"base"`
	Auto bool   `toml:"auto"`
}

type Index struct {
	Languages []string `toml:"languages"`
}

type Web struct {
	Port   int    `toml:"port"`
	Editor string `toml:"editor"`
	Open   bool   `toml:"open"`
}

func Defaults() Config {
	return Config{
		Agent:  Agent{Backend: "claude-code", Command: "claude"},
		Review: Review{Auto: true},
		Web:    Web{Port: 4040, Open: true},
	}
}

func GlobalPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "grasp", "config.toml")
}

func RepoPath(root string) string {
	return filepath.Join(root, ".grasp", "config.toml")
}

// Load layers defaults ← global ← repo. Missing files are fine; a file that
// exists but does not parse is an error worth surfacing.
func Load(root string) (Config, error) {
	cfg := Defaults()
	for _, path := range []string{GlobalPath(), RepoPath(root)} {
		if path == "" {
			continue
		}
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if _, err := toml.DecodeFile(path, &cfg); err != nil {
			return cfg, err
		}
	}
	return cfg, nil
}
