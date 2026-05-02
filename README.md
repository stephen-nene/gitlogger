# git-work

A bash script that wraps `git log` into a clean, human-friendly CLI. See what you (or your team) worked on — grouped by day, filtered by author, exported as JSON/CSV — all with zero dependencies.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/stephen-nene/gitlogger/main/gitwork.sh \
  -o /usr/local/bin/git-work && chmod +x /usr/local/bin/git-work
```

Or run directly without installing:

```bash
curl -fsSL https://raw.githubusercontent.com/stephen-nene/gitlogger/main/gitwork.sh \
  | bash -s -- today --me --oneline
```

## Usage

```
git-work [time] [options]
```

**Time shortcuts**

| shortcut | means |
|---|---|
| `today` | since midnight |
| `yesterday` | since yesterday 00:00 |
| `week` | last 7 days |
| `month` | last 30 days |
| `monday` | since last Monday |
| `3d` / `2w` / `1m` | N days / weeks / months ago |

**Author filters** (defaults to your `git config user.email`)

```bash
--me                          # you
--all                         # everyone
--authors alice@co,bob@co     # specific people
```

**Output modes**

```bash
--oneline     # compact, one line per commit
--stat        # files changed per commit
--summary     # totals: commits, files, insertions, deletions
--json        # JSON array export
--csv         # CSV export
--diff        # full patch output
```

**Other flags**

```bash
--no-merges           # skip merge commits
--grep "fix"          # filter by commit message
--path ~/other/repo   # run against a different repo
--yes / -y            # skip confirmation prompt
```

## Examples

```bash
# your commits today, grouped by day
git-work today

# your week with file stats, no merges
git-work week --stat --no-merges

# last 3 days summary dashboard
git-work 3d --summary

# a teammate's commits this week
git-work week --authors alice@company.com

# export the whole team's month as JSON
git-work month --all --json

# analyze a different repo
git-work week --path ~/projects/api --me
```
