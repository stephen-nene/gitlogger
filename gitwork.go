package main

import (
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	// "time"
)

type Commit struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Email   string `json:"email"`
	Date    string `json:"date"`
	Subject string `json:"subject"`
	Body    string `json:"body,omitempty"`
}

type Config struct {
	since          string
	until          string
	authors        []string
	allAuthors     bool
	mode           string
	merges         string
	repoDir        string
	filePath       string
	grepPatterns   []string
	doSummary      bool
	doJSON         bool
	doCSV          bool
	explicitAuthor bool
}

func main() {
	cfg := parseArgs()

	if err := validateRepo(cfg.repoDir); err != nil {
		fmt.Fprintf(os.Stderr, "❌ %v\n", err)
		os.Exit(1)
	}

	if !cfg.explicitAuthor {
		if email := getGitConfig(cfg.repoDir, "user.email"); email != "" {
			cfg.authors = append(cfg.authors, email)
		}
	}

	if cfg.doSummary {
		showSummary(cfg)
		return
	}

	commits := fetchCommits(cfg)

	if cfg.doJSON {
		outputJSON(commits)
	} else if cfg.doCSV {
		outputCSV(commits)
	} else {
		outputPretty(commits, cfg.mode)
	}
}

func parseArgs() *Config {
	cfg := &Config{
		repoDir: ".",
		mode:    "pretty",
	}

	var authorsStr string
	var help bool

	flag.BoolVar(&help, "help", false, "Show help")
	flag.BoolVar(&help, "h", false, "Show help")
	flag.StringVar(&cfg.since, "since", "", "Since date/time")
	flag.StringVar(&cfg.until, "until", "", "Until date/time")
	flag.StringVar(&authorsStr, "authors", "", "Comma-separated author emails")
	flag.BoolVar(&cfg.allAuthors, "all", false, "Show all authors")
	flag.StringVar(&cfg.mode, "oneline", "", "Oneline mode")
	flag.StringVar(&cfg.mode, "full", "", "Full mode")
	flag.StringVar(&cfg.mode, "stat", "", "Stat mode")
	flag.StringVar(&cfg.mode, "diff", "", "Diff mode")
	flag.StringVar(&cfg.mode, "files", "", "Files mode")
	flag.BoolVar(&cfg.doSummary, "summary", false, "Show summary")
	flag.BoolVar(&cfg.doJSON, "json", false, "JSON output")
	flag.BoolVar(&cfg.doCSV, "csv", false, "CSV output")
	flag.StringVar(&cfg.repoDir, "path", ".", "Repository path")
	flag.StringVar(&cfg.filePath, "file-path", "", "File path filter")

	flag.Usage = func() {
		fmt.Println(`Usage: gitwork [time-shortcut] [options]

Time shortcuts:
  today          Since midnight
  yesterday      Since yesterday 00:00
  week           Since 1 week ago
  month          Since 1 month ago
  monday         Since last Monday 00:00
  3d             Since 3 days ago (any <n>d / <n>w / <n>m)

Author options:
  --authors <emails>  Comma-separated author emails
  --all              Show all authors

Output modes:
  --oneline          Compact one line per commit
  --full             Full commit message
  --stat             Show files changed summary
  --diff             Show full diffs
  --files            Only file names
  --summary          Print summary statistics
  --json             Output as JSON
  --csv              Output as CSV

Filters:
  --path <dir>       Repository directory
  --file-path <dir>  Limit to subdirectory within repo

Examples:
  gitwork today
  gitwork week --authors alice@co.com
  gitwork month --json --all
  gitwork week --path ~/projects/api`)
		os.Exit(0)
	}

	flag.Parse()

	if help {
		flag.Usage()
	}

	// Parse time shortcuts from first positional arg
	args := flag.Args()
	if len(args) > 0 {
		cfg.since = parseTimeShortcut(args[0])
	}

	if authorsStr != "" {
		cfg.explicitAuthor = true
		for _, email := range strings.Split(authorsStr, ",") {
			email = strings.TrimSpace(email)
			if email != "" {
				cfg.authors = append(cfg.authors, email)
			}
		}
	}

	if cfg.allAuthors {
		cfg.explicitAuthor = true
		cfg.authors = nil
	}

	// Resolve repo path
	if absPath, err := filepath.Abs(cfg.repoDir); err == nil {
		cfg.repoDir = absPath
	}

	return cfg
}

func parseTimeShortcut(arg string) string {
	switch arg {
	case "today":
		return "midnight"
	case "yesterday":
		return "yesterday"
	case "week":
		return "1 week ago"
	case "month":
		return "1 month ago"
	case "monday":
		return "last Monday"
	default:
		if strings.HasSuffix(arg, "d") {
			return strings.TrimSuffix(arg, "d") + " days ago"
		}
		if strings.HasSuffix(arg, "w") {
			return strings.TrimSuffix(arg, "w") + " weeks ago"
		}
		if strings.HasSuffix(arg, "m") {
			return strings.TrimSuffix(arg, "m") + " months ago"
		}
		return arg
	}
}

func validateRepo(dir string) error {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--is-inside-work-tree")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("not a git repository: %s", dir)
	}
	return nil
}

func getGitConfig(dir, key string) string {
	cmd := exec.Command("git", "-C", dir, "config", key)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func fetchCommits(cfg *Config) []Commit {
	args := []string{"-C", cfg.repoDir, "log", "--pretty=format:%H\x1F%an\x1F%ae\x1F%aI\x1F%s\x1F%b\x1E"}

	if cfg.since != "" {
		args = append(args, "--since="+cfg.since)
	}
	if cfg.until != "" {
		args = append(args, "--until="+cfg.until)
	}
	for _, author := range cfg.authors {
		args = append(args, "--author="+author)
	}
	if cfg.filePath != "" {
		args = append(args, "--", cfg.filePath)
	}

	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var commits []Commit
	records := strings.Split(string(out), "\x1E")
	for _, rec := range records {
		rec = strings.TrimSpace(rec)
		if rec == "" {
			continue
		}
		fields := strings.Split(rec, "\x1F")
		if len(fields) < 5 {
			continue
		}
		commit := Commit{
			Hash:    fields[0][:7],
			Author:  fields[1],
			Email:   fields[2],
			Date:    fields[3],
			Subject: fields[4],
		}
		if len(fields) > 5 {
			commit.Body = strings.TrimSpace(fields[5])
		}
		commits = append(commits, commit)
	}
	return commits
}

func showSummary(cfg *Config) {
	commits := fetchCommits(cfg)
	fmt.Printf("%-18s %d\n", "Total commits:", len(commits))
}

func outputJSON(commits []Commit) {
	data, _ := json.MarshalIndent(commits, "", "  ")
	fmt.Println(string(data))
}

func outputCSV(commits []Commit) {
	w := csv.NewWriter(os.Stdout)
	w.Write([]string{"hash", "author", "date", "subject"})
	for _, c := range commits {
		w.Write([]string{c.Hash, c.Author, c.Date, c.Subject})
	}
	w.Flush()
}

func outputPretty(commits []Commit, mode string) {
	var prevDate string
	for _, c := range commits {
		date := c.Date[:10]
		if date != prevDate {
			if prevDate != "" {
				fmt.Println()
			}
			fmt.Printf("\n📅 \033[1;36m%s\033[0m\n", date)
			prevDate = date
		}
		fmt.Printf("  • \033[1;33m%s\033[0m %s\n", c.Hash, c.Subject)
		if c.Body != "" {
			for _, line := range strings.Split(c.Body, "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					fmt.Printf("    \033[90m%s\033[0m\n", line)
				}
			}
		}
	}
}
