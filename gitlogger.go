package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

type Commit struct {
	Date   string
	Hash   string
	Author string
	Msg    string
}

func main() {
	// ── Args ─────────────────────────────────────────────
	authorsArg := getArg(1, "")
	days := getArg(2, "15")
	repo := getArg(3, ".")

	if authorsArg == "" {
		authorsArg = getGitEmail(repo)
		if authorsArg == "" {
			fmt.Println("❌ No author email provided")
			os.Exit(1)
		}
	}

	since := fmt.Sprintf("%s days ago", days)
	authors := strings.Split(authorsArg, ",")

	// ── Validate repo ────────────────────────────────────
	if !isGitRepo(repo) {
		fmt.Println("❌ Not a git repository:", repo)
		os.Exit(1)
	}

	// ── Repo info ───────────────────────────────────────
	name := basename(getCmd(repo, "rev-parse", "--show-toplevel"))
	branch := getCmd(repo, "rev-parse", "--abbrev-ref", "HEAD")
	remote := getCmd(repo, "remote", "get-url", "origin")

	fmt.Println("\n📦 Repository Detected")
	fmt.Println("Name   :", name)
	fmt.Println("Branch :", branch)
	fmt.Println("Remote :", remote)
	fmt.Println("Authors:", authorsArg)
	fmt.Println("Period : last", days, "days\n")

	// ── Confirm ─────────────────────────────────────────
	fmt.Print("Analyse this repo? [y/N]: ")
	var input string
	fmt.Scanln(&input)
	if strings.ToLower(input) != "y" {
		fmt.Println("Aborted.")
		return
	}

	// ── Git log command ─────────────────────────────────
	args := []string{
		"-C", repo,
		"log",
		"--all",
		"--since=" + since,
		"--pretty=format:%ad|%h|%an|%s",
		"--date=short",
	}

	for _, a := range authors {
		args = append(args, "--author="+a)
	}

	cmd := exec.Command("git", args...)
	stdout, _ := cmd.StdoutPipe()
	cmd.Start()

	// ── Process stream ──────────────────────────────────
	scanner := bufio.NewScanner(stdout)

	var commits []Commit
	dateSet := make(map[string]bool)

	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, "|", 4)
		if len(parts) < 4 {
			continue
		}

		c := Commit{
			Date:   parts[0],
			Hash:   parts[1],
			Author: parts[2],
			Msg:    cleanMessage(parts[3]),
		}

		commits = append(commits, c)
		dateSet[c.Date] = true
	}

	cmd.Wait()

	if len(commits) == 0 {
		fmt.Println("No commits found.")
		return
	}

	// ── Report ──────────────────────────────────────────
	fmt.Println("\n📊 GIT TIMESHEET REPORT\n")

	currentDate := ""
	count := 0

	for _, c := range commits {
		if c.Date != currentDate {
			if currentDate != "" {
				fmt.Printf("  └─ %d commit(s)\n\n", count)
			}

			weekday := getWeekday(c.Date)

			fmt.Printf("📅 %s (%s)\n", c.Date, weekday)
			fmt.Println("────────────────────────────")

			currentDate = c.Date
			count = 0
		}

		fmt.Printf("• [%s] (%s) %s\n", c.Hash, c.Author, c.Msg)
		count++
	}

	fmt.Printf("  └─ %d commit(s)\n\n", count)

	// ── Stats ───────────────────────────────────────────
	activeDays := len(dateSet)
	total := len(commits)

	avg := 0.0
	if activeDays > 0 {
		avg = float64(total) / float64(activeDays)
	}

	fmt.Println("────────────────────────────")
	fmt.Println("Active days :", activeDays)
	fmt.Printf("Avg per day : %.1f\n", avg)
}

// ── Helpers ───────────────────────────────────────────

func getArg(i int, fallback string) string {
	if len(os.Args) > i {
		return os.Args[i]
	}
	return fallback
}

func getCmd(repo string, args ...string) string {
	out, _ := exec.Command("git", append([]string{"-C", repo}, args...)...).Output()
	return strings.TrimSpace(string(out))
}

func isGitRepo(repo string) bool {
	err := exec.Command("git", "-C", repo, "rev-parse", "--is-inside-work-tree").Run()
	return err == nil
}

func getGitEmail(repo string) string {
	out, _ := exec.Command("git", "-C", repo, "config", "user.email").Output()
	return strings.TrimSpace(string(out))
}

func basename(path string) string {
	parts := strings.Split(path, "/")
	return parts[len(parts)-1]
}

func cleanMessage(msg string) string {
	msg = strings.TrimSpace(msg)

	// remove prefixes
	prefixes := []string{"feat:", "fix:", "chore:", "docs:", "refactor:"}
	for _, p := range prefixes {
		msg = strings.TrimPrefix(strings.ToLower(msg), p)
	}

	msg = strings.TrimSpace(msg)

	if len(msg) > 0 {
		msg = strings.ToUpper(msg[:1]) + msg[1:]
	}

	return msg
}

func getWeekday(dateStr string) string {
	t, err := time.Parse("2006-01-02", dateStr)
	if err != nil {
		return ""
	}
	return t.Weekday().String()
}
