#!/usr/bin/env bash
# git-timesheet — summarise your commits as a daily timesheet
# Usage: git-timesheet [author_email] [days_ago]

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AUTHOR="${1:-$(git config user.email 2>/dev/null || echo "")}"
DAYS="${2:-15}"
SINCE="${DAYS} days ago"

# ── Colours (disabled when not a tty) ─────────────────────────────────────────
if [ -t 1 ]; then
  BOLD="\033[1m"; CYAN="\033[36m"; GREEN="\033[32m"
  YELLOW="\033[33m"; GREY="\033[90m"; RESET="\033[0m"
else
  BOLD=""; CYAN=""; GREEN=""; YELLOW=""; GREY=""; RESET=""
fi

# ── Validation ────────────────────────────────────────────────────────────────
if [ -z "$AUTHOR" ]; then
  echo "Usage: git-timesheet <author_email> [days_ago]"
  echo "  or set user.email in git config and run without arguments."
  exit 1
fi

# Check we are inside a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo -e "${BOLD}✗ Error:${RESET} You are not inside a git repository."
  echo "  Navigate into a git project folder and try again."
  exit 1
fi

# ── Repo confirmation ─────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "no remote")
BRANCH_COUNT=$(git branch --all 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │           Repository Detected                │${RESET}"
echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────────┘${RESET}"
echo -e "  ${GREY}Name     :${RESET} ${BOLD}${REPO_NAME}${RESET}"
echo -e "  ${GREY}Path     :${RESET} ${REPO_ROOT}"
echo -e "  ${GREY}Branch   :${RESET} ${CURRENT_BRANCH}"
echo -e "  ${GREY}Remote   :${RESET} ${REMOTE_URL}"
echo -e "  ${GREY}Branches :${RESET} ${BRANCH_COUNT} (local + remote)"
echo -e "  ${GREY}Author   :${RESET} ${AUTHOR}"
echo -e "  ${GREY}Period   :${RESET} last ${DAYS} days"
echo ""

# Prompt user — read from /dev/tty so it works even when stdin is piped
printf "  Analyse this repo? [y/N] "
read -r CONFIRM < /dev/tty

case "$CONFIRM" in
  [yY][eE][sS]|[yY]) ;;   # continue
  *)
    echo -e "\n  ${YELLOW}Aborted.${RESET} Navigate to the repo you want and run again.\n"
    exit 0
    ;;
esac
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────

# Cleans a raw commit message into a readable task line:
#   - strips ticket/issue prefixes like [PROJ-123], #42, feat:, fix(api):
#   - collapses whitespace
#   - title-cases the first word
clean_message() {
  echo "$1" \
    | sed -E 's/^\[?[A-Z]+-[0-9]+\]?[[:space:]:/-]*//' \
    | sed -E 's/^#[0-9]+[[:space:]]*//' \
    | sed -E 's/^(feat|fix|chore|docs|style|refactor|test|build|ci|perf|revert)(\([^)]*\))?[[:space:]]*:[[:space:]]*//' \
    | sed -E 's/^(Merge (branch|pull request|remote-tracking branch)[^$]*)/[merge] \1/' \
    | sed -E 's/[[:space:]]+/ /g' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//' \
    | awk '{ $1=toupper(substr($1,1,1)) substr($1,2); print }'
}

# ── Gather data ───────────────────────────────────────────────────────────────
# Format: DATE<TAB>HASH<TAB>SUBJECT<TAB>FILES_CHANGED<TAB>INSERTIONS<TAB>DELETIONS
RAW_LOG=$(git log --all \
  --author="$AUTHOR" \
  --since="$SINCE" \
  --pretty=format:"DATE:%ad|HASH:%h|MSG:%s" \
  --date=short \
  --no-merges 2>/dev/null || true)

MERGE_COUNT=$(git log --all \
  --author="$AUTHOR" \
  --since="$SINCE" \
  --merges \
  --oneline 2>/dev/null | wc -l | tr -d ' ')

if [ -z "$RAW_LOG" ]; then
  echo -e "${YELLOW}No commits found for ${AUTHOR} in the last ${DAYS} days.${RESET}"
  exit 0
fi

# ── Report header ─────────────────────────────────────────────────────────────
TOTAL_COMMITS=$(echo "$RAW_LOG" | wc -l | tr -d ' ')
FIRST_DATE=$(echo "$RAW_LOG" | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
LAST_DATE=$(echo "$RAW_LOG"  | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║              GIT TIMESHEET REPORT                   ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e "  ${GREY}Repo   :${RESET} ${BOLD}${REPO_NAME}${RESET}"
echo -e "  ${GREY}Author :${RESET} ${AUTHOR}"
echo -e "  ${GREY}Period :${RESET} ${FIRST_DATE}  →  ${LAST_DATE}  (last ${DAYS} days)"
echo -e "  ${GREY}Totals :${RESET} ${BOLD}${TOTAL_COMMITS}${RESET} commits  |  ${MERGE_COUNT} merges"
echo ""

# ── Group by day ──────────────────────────────────────────────────────────────
CURRENT_DATE=""
DAY_COUNT=0

while IFS= read -r line; do
  DATE=$(echo "$line" | grep -oP '(?<=DATE:)[^\|]+')
  HASH=$(echo "$line" | grep -oP '(?<=HASH:)[^\|]+')
  MSG=$(echo "$line"  | grep -oP '(?<=MSG:).+')

  # New day — print day header
  if [ "$DATE" != "$CURRENT_DATE" ]; then
    if [ -n "$CURRENT_DATE" ]; then
      echo -e "  ${GREY}└─ ${DAY_COUNT} commit(s)${RESET}"
      echo ""
    fi
    # Friendly weekday name
    WEEKDAY=$(date -d "$DATE" +"%A" 2>/dev/null || date -jf "%Y-%m-%d" "$DATE" +"%A" 2>/dev/null || echo "")
    echo -e "${BOLD}${GREEN}  ${DATE}  ${WEEKDAY}${RESET}"
    echo -e "  ${GREY}──────────────────────────────────────${RESET}"
    CURRENT_DATE="$DATE"
    DAY_COUNT=0
  fi

  TASK=$(clean_message "$MSG")
  DAY_COUNT=$((DAY_COUNT + 1))
  echo -e "  ${YELLOW}•${RESET} ${GREY}[${HASH}]${RESET} ${TASK}"

done <<< "$RAW_LOG"

# Close the last day block
if [ -n "$CURRENT_DATE" ]; then
  echo -e "  ${GREY}└─ ${DAY_COUNT} commit(s)${RESET}"
  echo ""
fi

# ── Stats footer ──────────────────────────────────────────────────────────────
# Count active days
ACTIVE_DAYS=$(echo "$RAW_LOG" \
  | grep -oP '(?<=DATE:)[^\|]+' \
  | sort -u | wc -l | tr -d ' ')

echo -e "${BOLD}${CYAN}  ─────────────────────────────────────────────────────${RESET}"
echo -e "  ${GREY}Active days :${RESET} ${ACTIVE_DAYS} / ${DAYS}"
echo -e "  ${GREY}Avg per day :${RESET} $(awk "BEGIN{printf \"%.1f\", ${TOTAL_COMMITS}/${ACTIVE_DAYS}}")"
echo ""




# # Create a personal bin folder if you don't have one
# mkdir -p ~/.local/bin

# # Move the downloaded script there (no .sh extension — cleaner to call)
# mv ~/Downloads/git-timesheet ~/.local/bin/git-timesheet

# # Make it executable
# chmod +x ~/.local/bin/git-timesheet
