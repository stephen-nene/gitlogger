#!/usr/bin/env python3
"""
gitwork - Git commit analyzer with time shortcuts and multiple output formats
"""

import argparse
import csv
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional


class Commit:
    def __init__(self, hash: str, author: str, email: str, date: str, subject: str, body: str = ""):
        self.hash = hash[:7]
        self.author = author
        self.email = email
        self.date = date
        self.subject = subject
        self.body = body.strip()

    def to_dict(self):
        d = {
            "hash": self.hash,
            "author": self.author,
            "email": self.email,
            "date": self.date,
            "subject": self.subject,
        }
        if self.body:
            d["body"] = self.body
        return d


class GitWork:
    def __init__(self):
        self.repo_dir = "."
        self.since = None
        self.until = None
        self.authors = []
        self.all_authors = False
        self.mode = "pretty"
        self.merges = ""
        self.file_path = ""
        self.grep_patterns = []
        self.explicit_author = False

    def parse_args(self):
        parser = argparse.ArgumentParser(
            description="Git commit analyzer",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Time shortcuts:
  today, yesterday, week, month, monday, 3d, 7d, 2w, 1m

Examples:
  gitwork.py today
  gitwork.py week --authors alice@co.com
  gitwork.py month --json --all
  gitwork.py week --path ~/projects/api
            """,
        )

        parser.add_argument("time", nargs="?", help="Time shortcut (today, week, 3d, etc)")
        parser.add_argument("--since", help="Since date/time")
        parser.add_argument("--until", help="Until date/time")
        parser.add_argument("--authors", help="Comma-separated author emails")
        parser.add_argument("--me", action="store_true", help="Include yourself")
        parser.add_argument("--all", action="store_true", dest="all_authors", help="Show all authors")
        parser.add_argument("--oneline", action="store_const", const="oneline", dest="mode")
        parser.add_argument("--full", action="store_const", const="full", dest="mode")
        parser.add_argument("--stat", action="store_const", const="stat", dest="mode")
        parser.add_argument("--diff", action="store_const", const="diff", dest="mode")
        parser.add_argument("--files", action="store_const", const="files", dest="mode")
        parser.add_argument("--summary", action="store_true", help="Show summary")
        parser.add_argument("--json", action="store_true", help="JSON output")
        parser.add_argument("--csv", action="store_true", help="CSV output")
        parser.add_argument("--no-merges", action="store_const", const="--no-merges", dest="merges")
        parser.add_argument("--only-merges", action="store_const", const="--merges", dest="merges")
        parser.add_argument("--path", help="Repository directory")
        parser.add_argument("--file-path", help="Limit to subdirectory within repo")
        parser.add_argument("--grep", action="append", dest="grep_patterns", help="Filter by message")

        args = parser.parse_args()

        # Parse time shortcut
        if args.time:
            self.since = self.parse_time_shortcut(args.time)
        if args.since:
            self.since = args.since
        if args.until:
            self.until = args.until

        # Authors
        if args.authors:
            self.explicit_author = True
            self.authors = [a.strip() for a in args.authors.split(",") if a.strip()]
        if args.me:
            self.explicit_author = True
            me = self.get_git_config("user.email")
            if me:
                self.authors.append(me)
        if args.all_authors:
            self.explicit_author = True
            self.authors = []

        # Mode
        if args.mode:
            self.mode = args.mode
        if args.json:
            self.mode = "json"
        if args.csv:
            self.mode = "csv"
        if args.summary:
            self.mode = "summary"

        # Filters
        if args.merges:
            self.merges = args.merges
        if args.file_path:
            self.file_path = args.file_path
        if args.grep_patterns:
            self.grep_patterns = args.grep_patterns

        # Repo path
        if args.path:
            self.repo_dir = os.path.abspath(args.path)
        else:
            self.repo_dir = os.getcwd()

    def parse_time_shortcut(self, shortcut: str) -> str:
        shortcuts = {
            "today": "midnight",
            "yesterday": "yesterday",
            "week": "1 week ago",
            "month": "1 month ago",
            "monday": "last Monday",
        }
        if shortcut in shortcuts:
            return shortcuts[shortcut]
        if shortcut.endswith("d"):
            return f"{shortcut[:-1]} days ago"
        if shortcut.endswith("w"):
            return f"{shortcut[:-1]} weeks ago"
        if shortcut.endswith("m"):
            return f"{shortcut[:-1]} months ago"
        return shortcut

    def validate_repo(self):
        try:
            subprocess.run(
                ["git", "-C", self.repo_dir, "rev-parse", "--is-inside-work-tree"],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError:
            print(f"❌ Not a git repository: {self.repo_dir}", file=sys.stderr)
            sys.exit(1)

    def get_git_config(self, key: str) -> Optional[str]:
        try:
            result = subprocess.run(
                ["git", "-C", self.repo_dir, "config", key],
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError:
            return None

    def fetch_commits(self) -> List[Commit]:
        cmd = ["git", "-C", self.repo_dir, "log", "--pretty=format:%H\x1F%an\x1F%ae\x1F%aI\x1F%s\x1F%b\x1E"]

        if self.since:
            cmd.append(f"--since={self.since}")
        if self.until:
            cmd.append(f"--until={self.until}")
        if self.merges:
            cmd.append(self.merges)
        for author in self.authors:
            cmd.append(f"--author={author}")
        for pattern in self.grep_patterns:
            cmd.append(f"--grep={pattern}")
        if self.file_path:
            cmd.extend(["--", self.file_path])

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            return []

        commits = []
        for record in result.stdout.split("\x1E"):
            record = record.strip()
            if not record:
                continue
            fields = record.split("\x1F")
            if len(fields) < 5:
                continue
            commit = Commit(
                hash=fields[0],
                author=fields[1],
                email=fields[2],
                date=fields[3],
                subject=fields[4],
                body=fields[5] if len(fields) > 5 else "",
            )
            commits.append(commit)
        return commits

    def output_json(self, commits: List[Commit]):
        data = [c.to_dict() for c in commits]
        print(json.dumps(data, indent=2))

    def output_csv(self, commits: List[Commit]):
        writer = csv.writer(sys.stdout)
        writer.writerow(["hash", "author", "date", "subject"])
        for c in commits:
            writer.writerow([c.hash, c.author, c.date, c.subject])

    def output_summary(self, commits: List[Commit]):
        print(f"{'Total commits:':<18} {len(commits)}")

    def output_pretty(self, commits: List[Commit]):
        prev_date = None
        for c in commits:
            date = c.date[:10]
            if date != prev_date:
                if prev_date:
                    print()
                print(f"\n📅 \033[1;36m{date}\033[0m")
                prev_date = date
            print(f"  • \033[1;33m{c.hash}\033[0m {c.subject}")
            if c.body:
                for line in c.body.split("\n"):
                    line = line.strip()
                    if line:
                        print(f"    \033[90m{line}\033[0m")

    def run(self):
        self.parse_args()
        self.validate_repo()

        # Default to --me if no explicit author
        if not self.explicit_author:
            me = self.get_git_config("user.email")
            if me:
                self.authors = [me]

        commits = self.fetch_commits()

        if self.mode == "json":
            self.output_json(commits)
        elif self.mode == "csv":
            self.output_csv(commits)
        elif self.mode == "summary":
            self.output_summary(commits)
        else:
            self.output_pretty(commits)


if __name__ == "__main__":
    GitWork().run()
