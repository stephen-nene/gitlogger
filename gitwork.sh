#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
GRAY='\033[90m'
RESET='\033[0m'
DIM='\033[2m'

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: git-work [time-shortcut] [options]

Time shortcuts:
  today          Since midnight
  yesterday      Since yesterday 00:00
  week           Since 1 week ago
  month          Since 1 month ago
  monday         Since last Monday 00:00
  3d             Since 3 days ago (any <n>d / <n>w / <n>m)
  <date>         Passes through to --since (e.g. "2026-04-01")

Author options (defaults to --me if no author specified):
  --authors <email1,email2>  Comma-separated list of author emails
  --me                       Include yourself (git config user.email)
  --all                      Show all authors (overrides default --me behavior)

Output modes:
  --oneline              Compact one line per commit
  --full                 Full commit message
  --stat                 Show files changed summary
  --diff                 Show full diffs (like -p)
  --files                Only file names
  --summary              Print total commits, files, insertions, deletions
  --json                 Output as JSON array
  --csv                  Output as CSV (hash, author, date, subject)

Filters:
  --no-merges            Exclude merge commits
  --only-merges          Only merge commits
  --include-merges       (default) include merges
  --path <dir>           Repository directory (absolute or relative)
  --file-path <dir>      Limit to a subdirectory within repo
  --grep <pattern>       Filter by commit message (can use multiple times)
  --yes, -y              Skip confirmation prompt

Examples:
  git-work today                              # your commits today
  git-work today --all                        # everyone's commits today
  git-work week --authors alice@co.com        # alice's week
  git-work week --authors alice@co,bob@ --me  # alice + bob + you
  git-work week --authors alice@co            # alice only (no auto-me)
  git-work monday --stat --no-merges          # your non-merge commits since monday
  git-work 3d --summary --no-merges           # your stats for 3 days
  git-work month --json --all                 # full team export
  git-work week --path ~/projects/api         # analyze different repo
EOF
  exit 0
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
SINCE=""
UNTIL=""
AUTHORS_STRING=""
ALL_AUTHORS=false
MODE="pretty"
MERGES=""
PATH_SCOPE=""
REPO_DIR="."
GREP_PATTERNS=()
DO_SUMMARY=false
DO_JSON=false
DO_CSV=false
EXPLICIT_AUTHOR=false
SKIP_CONFIRM=false

# ─── Parse time shortcuts (first argument) ────────────────────────────────────
if [[ $# -gt 0 ]]; then
  case "$1" in
    today)      SINCE="midnight" ; shift ;;
    yesterday)  SINCE="yesterday" ; shift ;;
    week)       SINCE="1 week ago" ; shift ;;
    month)      SINCE="1 month ago" ; shift ;;
    monday)     SINCE="last Monday" ; shift ;;
    *[0-9]d)    SINCE="${1%d} days ago" ; shift ;;
    *[0-9]w)    SINCE="${1%w} weeks ago" ; shift ;;
    *[0-9]m)    SINCE="${1%m} months ago" ; shift ;;
    *)          ;;
  esac
fi

# ─── Parse flags ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;

    --authors)
      EXPLICIT_AUTHOR=true
      if [[ -n "$AUTHORS_STRING" ]]; then
        AUTHORS_STRING+=",$2"
      else
        AUTHORS_STRING="$2"
      fi
      shift 2 ;;

    --me)
      EXPLICIT_AUTHOR=true
      me="$(git -C "$REPO_DIR" config user.email 2>/dev/null || true)"
      [[ -z "$me" ]] && { echo "❌ Could not detect user.email from git config" >&2; exit 1; }
      if [[ -n "$AUTHORS_STRING" ]]; then
        AUTHORS_STRING+=",$me"
      else
        AUTHORS_STRING="$me"
      fi
      shift ;;

    --all)
      EXPLICIT_AUTHOR=true
      AUTHORS_STRING=""
      shift ;;

    --oneline) MODE="oneline"; shift ;;
    --full) MODE="full"; shift ;;
    --stat) MODE="stat"; shift ;;
    --diff) MODE="diff"; shift ;;
    --files) MODE="files"; shift ;;
    --no-merges) MERGES="--no-merges"; shift ;;
    --only-merges) MERGES="--merges"; shift ;;
    --include-merges) MERGES=""; shift ;;
    --path)
      if [[ "$2" == /* ]]; then
        REPO_DIR="$2"
      else
        REPO_DIR="$(pwd)/$2"
      fi
      shift 2 ;;
    --file-path) PATH_SCOPE="$2"; shift 2 ;;

    --grep)
      GREP_PATTERNS+=("$2")
      shift 2 ;;

    --summary) DO_SUMMARY=true; shift ;;
    --json) DO_JSON=true; MODE="json"; shift ;;
    --csv) DO_CSV=true; MODE="csv"; shift ;;
    --yes|-y) SKIP_CONFIRM=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ─── NOW check if we're in a git repo (after parsing --path) ─────────────────
REPO_DIR=$(cd "$REPO_DIR" 2>/dev/null && pwd || echo "$REPO_DIR")
git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "❌ Not a git repository: $REPO_DIR" >&2
  exit 1
}

# ─── Repository detection and confirmation prompt ────────────────────────────
display_repo_info_and_confirm() {
  local repo_name repo_path branch remote branch_count period_text

  repo_name=$(basename "$(git -C "$REPO_DIR" rev-parse --show-toplevel)")
  repo_path="$REPO_DIR"
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
  remote=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "none")
  branch_count=$(git -C "$REPO_DIR" branch --all 2>/dev/null | wc -l | xargs)

  # Format period text
  if [[ -n "$SINCE" ]]; then
    period_text="$SINCE"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    period_text="last $1 days"
  else
    period_text="all time"
  fi

  # Format authors display
  local authors_display=""
  if [[ -n "$AUTHORS_STRING" ]]; then
    authors_display="$AUTHORS_STRING"
  elif $ALL_AUTHORS || ($EXPLICIT_AUTHOR && [[ -z "$AUTHORS_STRING" ]]); then
    authors_display="all committers"
  else
    authors_display="$(git -C "$REPO_DIR" config user.email || echo "unknown")"
  fi

  # Draw box
  local box_width=47
  printf "\n"
  printf "  ${CYAN}┌─────────────────────────────────────────────┐${RESET}\n"
  printf "  ${CYAN}│${RESET}           ${BOLD}Repository Detected${RESET}                ${CYAN}│${RESET}\n"
  printf "  ${CYAN}└─────────────────────────────────────────────┘${RESET}\n"
  printf "  ${GRAY}Name${RESET}      : ${GREEN}%s${RESET}\n" "$repo_name"
  printf "  ${GRAY}Path${RESET}      : ${GREEN}%s${RESET}\n" "$repo_path"
  printf "  ${GRAY}Branch${RESET}    : ${YELLOW}%s${RESET}\n" "$branch"
  printf "  ${GRAY}Remote${RESET}    : ${GREEN}%s${RESET}\n" "$remote"
  printf "  ${GRAY}Branches${RESET}  : ${GREEN}%s${RESET}\n" "$branch_count"
  printf "  ${GRAY}Author(s)${RESET} : ${GREEN}%s${RESET}\n" "$authors_display"
  printf "  ${GRAY}Period${RESET}    : ${YELLOW}%s${RESET}\n" "$period_text"
  printf "\n"

  if ! $SKIP_CONFIRM; then
    printf "  ${BOLD}Analyse this repo? [y/N] ${RESET}"
    read -r response
    echo
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      printf "  ${DIM}Exiting without analysis.${RESET}\n"
      exit 0
    fi
  fi
  echo
}

# Show repo info and confirm (pass original time arg for display)
display_repo_info_and_confirm

# ─── Smart default: if no --authors, --me, or --all given → use --me ─────────
if ! $EXPLICIT_AUTHOR; then
  me="$(git -C "$REPO_DIR" config user.email)"
  if [[ -n "$me" ]]; then
    AUTHORS_STRING="$me"
  fi
fi

# ─── Build base git log command ───────────────────────────────────────────────
BASE_CMD="git -C \"$REPO_DIR\" log"
[[ -n "$SINCE" ]]  && BASE_CMD+=" --since=\"$SINCE\""
[[ -n "$UNTIL" ]]  && BASE_CMD+=" --until=\"$UNTIL\""
[[ -n "$MERGES" ]] && BASE_CMD+=" $MERGES"

# Add author filters
if [[ -n "$AUTHORS_STRING" ]]; then
  IFS=',' read -ra AUTHORS_ARRAY <<< "$AUTHORS_STRING"
  for author in "${AUTHORS_ARRAY[@]}"; do
    author_trimmed="$(echo "$author" | xargs)"
    [[ -n "$author_trimmed" ]] && BASE_CMD+=" --author=\"$author_trimmed\""
  done
fi

# Add grep filters
for pattern in "${GREP_PATTERNS[@]}"; do
  BASE_CMD+=" --grep=\"$pattern\""
done

# Add path scope at the end
[[ -n "$PATH_SCOPE" ]] && BASE_CMD+=" -- $PATH_SCOPE"

# ─── Summary mode ─────────────────────────────────────────────────────────────
if $DO_SUMMARY; then
  TEMP_FILE=$(mktemp)
  eval "$BASE_CMD --shortstat > $TEMP_FILE" 2>/dev/null || true

  COMMITS=$(grep -c '^commit ' "$TEMP_FILE" || echo 0)
  FILES_CHANGED=$(grep -oP '\d+(?= files? changed)' "$TEMP_FILE" | paste -sd+ | bc 2>/dev/null || echo 0)
  INSERTIONS=$(grep -oP '\d+(?= insertions?\b)' "$TEMP_FILE" | paste -sd+ | bc 2>/dev/null || echo 0)
  DELETIONS=$(grep -oP '\d+(?= deletions?\b)' "$TEMP_FILE" | paste -sd+ | bc 2>/dev/null || echo 0)
  rm "$TEMP_FILE"

  printf "%-18s %s\n" "Total commits:" "$COMMITS"
  printf "%-18s %s\n" "Files changed:" "${FILES_CHANGED:-0}"
  printf "%-18s %s\n" "Insertions:" "${INSERTIONS:-0}"
  printf "%-18s %s\n" "Deletions:" "${DELETIONS:-0}"
  exit 0
fi

# ─── JSON mode ────────────────────────────────────────────────────────────────
if $DO_JSON; then
  echo "["
  eval "$BASE_CMD --pretty=format:'{\"hash\":\"%H\",\"author\":\"%an\",\"email\":\"%ae\",\"date\":\"%aI\",\"subject\":\"%s\"},'" \
    | sed '$ s/,$//'
  echo "]"
  exit 0
fi

# ─── CSV mode ─────────────────────────────────────────────────────────────────
if $DO_CSV; then
  echo "hash,author,date,subject"
  eval "$BASE_CMD --pretty=format:'%H,%an,%aI,%s'"
  exit 0
fi

# ─── Output modes ─────────────────────────────────────────────────────────────
case "$MODE" in
  oneline) eval "$BASE_CMD --oneline" ;;
  full)    eval "$BASE_CMD" ;;
  stat)    eval "$BASE_CMD --stat" ;;
  diff)    eval "$BASE_CMD -p" ;;
  files)   eval "$BASE_CMD --name-only" ;;

  pretty)
    # Use %x1E (record separator) to delimit commits, %x1F for fields
    eval "$BASE_CMD --pretty=format:'%ad%x1F%h%x1F%s%x1F%b%x1E' --date=short" \
      | awk 'BEGIN { RS="\036"; FS="\037" }
      NF > 0 {
        date = $1; hash = $2; subject = $3; body = $4
        if (date != prev_date) {
          if (prev_date != "") print ""
          printf "\n📅 \033[1;36m%s\033[0m\n", date
          prev_date = date
        }
        printf "  • \033[1;33m%s\033[0m %s", hash, subject
        if (body != "" && body !~ /^[[:space:]]*$/) {
          # Print body lines indented
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", body)
          n = split(body, lines, "\n")
          for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lines[i])
            if (lines[i] != "") {
              printf "\n    \033[90m%s\033[0m", lines[i]
            }
          }
        }
        printf "\n"
      }'
    ;;
esac
