#!/usr/bin/env bash
# git-timesheet — summarise your commits as a daily timesheet (Excel output)
# Usage: git-timesheet [author_email] [days_ago]

set -euo pipefail

AUTHOR="${1:-$(git config user.email 2>/dev/null || echo "")}"
DAYS="${2:-15}"
SINCE="${DAYS} days ago"

OUTPUT_DIR="$PWD"
OUTPUT_FILE="${OUTPUT_DIR}/git-timesheet-$(date +%Y-%m-%d).xlsx"

if [ -t 1 ]; then
  BOLD="\033[1m"; CYAN="\033[36m"; GREEN="\033[32m"
  YELLOW="\033[33m"; GREY="\033[90m"; RESET="\033[0m"
else
  BOLD=""; CYAN=""; GREEN=""; YELLOW=""; GREY=""; RESET=""
fi

if [ -z "$AUTHOR" ]; then
  echo "Usage: git-timesheet <author_email> [days_ago]"
  echo "  or set user.email in git config and run without arguments."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo -e "${BOLD}✗ Error:${RESET} You are not inside a git repository."
  exit 1
fi

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
echo -e "  ${GREY}Output   :${RESET} ${OUTPUT_FILE}"
echo ""

printf "  Analyse this repo? [y/N] "
read -r CONFIRM < /dev/tty

case "$CONFIRM" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo -e "\n  ${YELLOW}Aborted.${RESET}\n"
    exit 0
    ;;
esac
echo ""

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

TOTAL_COMMITS=$(echo "$RAW_LOG" | wc -l | tr -d ' ')
FIRST_DATE=$(echo "$RAW_LOG" | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
LAST_DATE=$(echo "$RAW_LOG"  | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
ACTIVE_DAYS=$(echo "$RAW_LOG" | grep -oP '(?<=DATE:)[^\|]+' | sort -u | wc -l | tr -d ' ')

# Write commits to a temp CSV — avoids all heredoc/stdin conflicts
TMPCSV=$(mktemp /tmp/gt-XXXXXX.csv)
TMPPY=$(mktemp /tmp/gt-XXXXXX.py)
trap 'rm -f "$TMPCSV" "$TMPPY"' EXIT

while IFS= read -r line; do
  DATE=$(echo "$line" | grep -oP '(?<=DATE:)[^\|]+')
  HASH=$(echo "$line" | grep -oP '(?<=HASH:)[^\|]+')
  MSG=$(echo "$line"  | grep -oP '(?<=MSG:).+')
  TASK=$(clean_message "$MSG")
  TASK_ESC=$(echo "$TASK" | sed 's/"/""/g')
  printf '%s,%s,"%s"\n' "$DATE" "$HASH" "$TASK_ESC" >> "$TMPCSV"
done <<< "$RAW_LOG"

# Write the Python script to its own temp file — no heredoc nesting issues
python3 -c "
import sys
script = open(sys.argv[1]).read()
open(sys.argv[2], 'w').write(script)
" /dev/stdin "$TMPPY" << 'PYEOF'
import sys, csv
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from datetime import datetime
from collections import OrderedDict

OUTPUT_FILE   = sys.argv[1]
REPO_NAME     = sys.argv[2]
AUTHOR        = sys.argv[3]
FIRST_DATE    = sys.argv[4]
LAST_DATE     = sys.argv[5]
DAYS          = sys.argv[6]
TOTAL_COMMITS = int(sys.argv[7])
MERGE_COUNT   = int(sys.argv[8])
ACTIVE_DAYS   = int(sys.argv[9])
CSV_FILE      = sys.argv[10]

commits = []
with open(CSV_FILE, newline='', encoding='utf-8') as f:
    for row in csv.reader(f):
        if len(row) >= 3:
            commits.append({"date": row[0], "hash": row[1], "msg": row[2]})

DARK_BG   = "1E2A3A"
MID_BG    = "2D3F52"
ACCENT    = "4A9EFF"
LIGHT_ROW = "F4F7FA"
ALT_ROW   = "E8EFF7"
WHITE     = "FFFFFF"
BORDER_C  = "C8D6E5"

thin     = Side(style="thin", color=BORDER_C)
full_bdr = Border(left=thin, right=thin, top=thin, bottom=thin)

def fill(c):         return PatternFill("solid", fgColor=c)
def center(w=False): return Alignment(horizontal="center", vertical="center", wrap_text=w)
def left(w=True):    return Alignment(horizontal="left",   vertical="center", wrap_text=w)

wb = Workbook()

# Sheet 1 — Timesheet
ws = wb.active
ws.title = "Timesheet"
ws.sheet_view.showGridLines = False
ws.freeze_panes = "A5"

for col, w in [("A",14),("B",13),("C",11),("D",64)]:
    ws.column_dimensions[col].width = w

ws.merge_cells("A1:D1")
c = ws["A1"]
c.value = f"Git Timesheet  ·  {REPO_NAME}"
c.font  = Font(name="Arial", size=15, bold=True, color=WHITE)
c.fill  = fill(DARK_BG); c.alignment = center()
ws.row_dimensions[1].height = 34

ws.merge_cells("A2:D2")
c = ws["A2"]
c.value = f"Author: {AUTHOR}     Period: {FIRST_DATE}  \u2192  {LAST_DATE}   (last {DAYS} days)"
c.font  = Font(name="Arial", size=9, color="A8C4E0")
c.fill  = fill(DARK_BG); c.alignment = center()
ws.row_dimensions[2].height = 18

stats = [
    ("A3", str(TOTAL_COMMITS), "Commits"),
    ("B3", str(ACTIVE_DAYS),   "Active Days"),
    ("C3", str(MERGE_COUNT),   "Merges"),
    ("D3", f"{TOTAL_COMMITS/ACTIVE_DAYS:.1f}" if ACTIVE_DAYS else "0", "Avg / Day"),
]
ws.row_dimensions[3].height = 38
for ref, val, lbl in stats:
    c = ws[ref]
    c.value     = f"{val}\n{lbl}"
    c.font      = Font(name="Arial", size=11, bold=True, color=WHITE)
    c.fill      = fill(MID_BG)
    c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    c.border    = Border(bottom=Side(style="medium", color=ACCENT))

for col, hdr in enumerate(["Date","Weekday","Hash","Commit Message"], 1):
    c = ws.cell(row=4, column=col, value=hdr)
    c.font = Font(name="Arial", size=10, bold=True, color=WHITE)
    c.fill = fill(ACCENT); c.alignment = center(); c.border = full_bdr
ws.row_dimensions[4].height = 22

prev_date = None
for i, commit in enumerate(commits):
    r      = i + 5
    is_new = commit["date"] != prev_date
    try:
        weekday = datetime.strptime(commit["date"], "%Y-%m-%d").strftime("%A")
    except ValueError:
        weekday = ""
    row_fill = fill(LIGHT_ROW) if i % 2 == 0 else fill(ALT_ROW)

    c = ws.cell(row=r, column=1, value=commit["date"] if is_new else "")
    c.font = Font(name="Arial", size=10, bold=is_new, color="1A252F" if is_new else "BBBBBB")
    c.fill = row_fill; c.alignment = center(); c.border = full_bdr

    c = ws.cell(row=r, column=2, value=weekday if is_new else "")
    c.font = Font(name="Arial", size=10, color="5D6D7E")
    c.fill = row_fill; c.alignment = center(); c.border = full_bdr

    c = ws.cell(row=r, column=3, value=commit["hash"])
    c.font = Font(name="Courier New", size=9, color="7F8C8D")
    c.fill = row_fill; c.alignment = center(); c.border = full_bdr

    c = ws.cell(row=r, column=4, value=commit["msg"])
    c.font = Font(name="Arial", size=10, color="2C3E50")
    c.fill = row_fill; c.alignment = left(); c.border = full_bdr

    ws.row_dimensions[r].height = 18
    prev_date = commit["date"]

# Sheet 2 — Summary
ws2 = wb.create_sheet("Summary")
ws2.sheet_view.showGridLines = False

for col, w in [("A",16),("B",14),("C",14)]:
    ws2.column_dimensions[col].width = w

ws2.merge_cells("A1:C1")
c = ws2["A1"]
c.value = "Daily Commit Summary"
c.font  = Font(name="Arial", size=13, bold=True, color=WHITE)
c.fill  = fill(DARK_BG); c.alignment = center()
ws2.row_dimensions[1].height = 30

for col, hdr in enumerate(["Date","Weekday","Commits"], 1):
    c = ws2.cell(row=2, column=col, value=hdr)
    c.font = Font(name="Arial", size=10, bold=True, color=WHITE)
    c.fill = fill(ACCENT); c.alignment = center(); c.border = full_bdr
ws2.row_dimensions[2].height = 22

day_counts = OrderedDict()
for commit in commits:
    d = commit["date"]
    day_counts[d] = day_counts.get(d, 0) + 1

for i, (date_str, count) in enumerate(day_counts.items()):
    r = i + 3
    try:
        weekday = datetime.strptime(date_str, "%Y-%m-%d").strftime("%A")
    except ValueError:
        weekday = ""
    row_fill = fill(LIGHT_ROW) if i % 2 == 0 else fill(ALT_ROW)
    for col, val in enumerate([date_str, weekday, count], 1):
        c = ws2.cell(row=r, column=col, value=val)
        c.font = Font(name="Arial", size=10, color="2C3E50")
        c.fill = row_fill; c.alignment = center(); c.border = full_bdr
    ws2.row_dimensions[r].height = 18

tr = len(day_counts) + 3
for col, val in enumerate(["TOTAL", f"{ACTIVE_DAYS} days", f"=SUM(C3:C{tr-1})"], 1):
    c = ws2.cell(row=tr, column=col, value=val)
    c.font = Font(name="Arial", size=10, bold=True, color="1A252F")
    c.fill = fill("D5E8F0"); c.alignment = center(); c.border = full_bdr
ws2.row_dimensions[tr].height = 22

wb.save(OUTPUT_FILE)
PYEOF

if ! python3 -c "import openpyxl" 2>/dev/null; then
  echo -e "${YELLOW}  openpyxl not found — installing...${RESET}"
  pip3 install openpyxl --quiet 2>/dev/null || {
    echo -e "${BOLD}✗ Error:${RESET} Could not install openpyxl. Run: pip install openpyxl"
    exit 1
  }
fi

python3 "$TMPPY" \
  "$OUTPUT_FILE" "$REPO_NAME" "$AUTHOR" "$FIRST_DATE" "$LAST_DATE" \
  "$DAYS" "$TOTAL_COMMITS" "$MERGE_COUNT" "$ACTIVE_DAYS" "$TMPCSV"

echo ""
echo -e "${BOLD}${GREEN}  ✓ Timesheet saved to:${RESET}"
echo -e "    ${CYAN}${OUTPUT_FILE}${RESET}"
echo ""
