#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gitlogger v2.1  —  multi-author, multi-format git timesheet
#
# UPDATES in v2.1:
#   --author      accepts comma-separated emails: -a "a@b.com,c@d.com"
#   Email regex   validates email format before processing
#   Full messages  includes commit body (bullet points, multi-line messages)
#   JSON escaping  properly handles newlines and quotes in full messages
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Bash 4+ required (for associative arrays, mapfile) ────────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'Error: gitlogger requires bash 4.0+ (current: %s)\n' "$BASH_VERSION" >&2
  printf 'macOS: brew install bash && hash -r\n' >&2
  exit 1
fi

readonly VERSION="2.1.0"

# ── Defaults ──────────────────────────────────────────────────────────────────
AUTHORS=()
DAYS=15
DIR="."
FORMAT="terminal"    # terminal | json | csv | md
GROUP_BY="day"       # day | type
INCLUDE_MERGES=false
SHOW_STATS=true
SKIP_CONFIRM=false

# ── Colors ────────────────────────────────────────────────────────────────────
B="" C="" Gr="" Y="" Gy="" Rs=""
init_colors() {
  # Colors only when writing to a terminal in terminal format
  [[ "$FORMAT" == "terminal" && -t 1 ]] || return 0
  B=$'\033[1m' C=$'\033[36m' Gr=$'\033[32m' Y=$'\033[33m' Gy=$'\033[90m' Rs=$'\033[0m'
}

# ── Conventional commit type → display label ──────────────────────────────────
declare -A TYPE_LABELS=(
  [feat]="✨ Features"        [fix]="🐛 Bug Fixes"
  [docs]="📝 Documentation"   [refactor]="♻️  Refactor"
  [test]="🧪 Tests"           [chore]="🔧 Chore"
  [style]="💅 Style"          [perf]="⚡ Performance"
  [ci]="🏗️  CI / Build"       [build]="🏗️  CI / Build"
  [revert]="⏪ Reverts"        [other]="📌 Other"
)

# ── Email validation ──────────────────────────────────────────────────────────
validate_email() {
  local email="$1"
  # RFC 5322 compliant-ish pattern
  [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
gitlogger v${VERSION} — git commit timesheet

Usage: gitlogger [OPTIONS]

  -a, --author <email>    Author email(s) - repeat flag or comma-separated
  -d, --dir <path>        Repo path (default: current directory)
  -n, --days <N>          Days to look back (default: 15)
  -f, --format <fmt>      terminal | json | csv | md  (default: terminal)
  -g, --group-by <by>     day | type  (default: day)
  -m, --merges            Include merge commits (default: excluded)
  -y, --yes               Skip confirmation prompt
      --no-stats          Hide summary footer
  -v, --version           Print version
  -h, --help              Show this help

Examples:
  gitlogger -a me@example.com -n 7
  gitlogger -a "alice@co.com,bob@co.com" -n 30 --format md > sprint.md
  gitlogger -a alice@co.com -a bob@co.com -d ~/projects/api --group-by type
  gitlogger --format json | jq '.commits | length'
  gitlogger --format csv | sort -t, -k1
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--author)
        # Handle comma-separated emails
        IFS=',' read -ra emails <<< "$2"
        for e in "${emails[@]}"; do
          # Trim whitespace
          e_trimmed="$(echo "$e" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$e_trimmed" ]] && AUTHORS+=("$e_trimmed")
        done
        shift 2 ;;
      -d|--dir)      DIR="$2";             shift 2 ;;
      -n|--days)     DAYS="$2";            shift 2 ;;
      -f|--format)   FORMAT="$2";          shift 2 ;;
      -g|--group-by) GROUP_BY="$2";        shift 2 ;;
      -m|--merges)   INCLUDE_MERGES=true;  shift   ;;
      -y|--yes)      SKIP_CONFIRM=true;    shift   ;;
      --no-stats)    SHOW_STATS=false;     shift   ;;
      -v|--version)  printf 'gitlogger v%s\n' "$VERSION"; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      # ── Legacy positional: gitlogger <email> [days] ──────────────────────
      *)
        if [[ "$1" == *@* && ${#AUTHORS[@]} -eq 0 ]]; then
          AUTHORS+=("$1"); shift
        elif [[ "$1" =~ ^[0-9]+$ ]]; then
          DAYS="$1"; shift
        else
          printf 'Error: unknown option: %s\n\n' "$1" >&2
          usage >&2; exit 1
        fi ;;
    esac
  done
}

# ── Validation ────────────────────────────────────────────────────────────────
validate() {
  [[ -d "$DIR" ]] || { printf 'Error: directory not found: %s\n' "$DIR" >&2; exit 1; }
  cd -- "$DIR"

  git rev-parse --is-inside-work-tree &>/dev/null \
    || { printf 'Error: not a git repository: %s\n' "$(pwd)" >&2; exit 1; }

  # Fall back to git config user.email
  if (( ${#AUTHORS[@]} == 0 )); then
    local default_email
    default_email=$(git config user.email 2>/dev/null || true)
    [[ -n "$default_email" ]] \
      || { printf 'Error: no --author given and git user.email is not set\n' >&2; exit 1; }
    AUTHORS+=("$default_email")
  fi

  # Validate all email formats
  for email in "${AUTHORS[@]}"; do
    if ! validate_email "$email"; then
      printf 'Error: invalid email format: %s\n' "$email" >&2
      exit 1
    fi
  done

  # Strict positive-integer check — avoids division-by-zero and bad git --since
  [[ "$DAYS" =~ ^[1-9][0-9]*$ ]] \
    || { printf 'Error: --days must be a positive integer, got: %s\n' "$DAYS" >&2; exit 1; }

  case "$FORMAT"   in terminal|json|csv|md) ;; *)
    printf 'Error: unknown --format: %s  (terminal|json|csv|md)\n' "$FORMAT" >&2; exit 1 ;; esac
  case "$GROUP_BY" in day|type) ;; *)
    printf 'Error: unknown --group-by: %s  (day|type)\n' "$GROUP_BY" >&2; exit 1 ;; esac
}

# ── Repository info banner ────────────────────────────────────────────────────
repo_banner() {
  local root name branch remote bcount author_str
  root=$(git rev-parse --show-toplevel)
  name=$(basename "$root")
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
  remote=$(git remote get-url origin 2>/dev/null || printf 'no remote')
  bcount=$(git branch --all 2>/dev/null | wc -l | tr -d ' ')
  author_str=$(IFS=', '; printf '%s' "${AUTHORS[*]}")

  printf '\n'
  printf '%s  ┌─────────────────────────────────────────────┐%s\n' "${B}${C}" "${Rs}"
  printf '%s  │           Repository Detected                │%s\n' "${B}${C}" "${Rs}"
  printf '%s  └─────────────────────────────────────────────┘%s\n' "${B}${C}" "${Rs}"
  printf '  %sName      :%s %s%s%s\n'       "${Gy}" "${Rs}" "${B}" "$name"        "${Rs}"
  printf '  %sPath      :%s %s\n'           "${Gy}" "${Rs}" "$root"
  printf '  %sBranch    :%s %s\n'           "${Gy}" "${Rs}" "$branch"
  printf '  %sRemote    :%s %s\n'           "${Gy}" "${Rs}" "$remote"
  printf '  %sBranches  :%s %s\n'           "${Gy}" "${Rs}" "$bcount"
  printf '  %sAuthor(s) :%s %s\n'           "${Gy}" "${Rs}" "$author_str"
  printf '  %sPeriod    :%s last %s days\n' "${Gy}" "${Rs}" "$DAYS"
  printf '\n'
}

# ── Confirmation prompt ───────────────────────────────────────────────────────
confirm_or_exit() {
  $SKIP_CONFIRM && return 0
  printf '  Analyse this repo? [y/N] '
  local ans; read -r ans </dev/tty
  case "$ans" in
    [yY]*) printf '\n' ;;
    *) printf '\n  %sAborted.%s\n\n' "${Y}" "${Rs}"; exit 0 ;;
  esac
}

# ── Core: fetch + parse commits ───────────────────────────────────────────────
# Internal record separator: \x01 (ASCII SOH) — won't appear in commit subjects
# Output fields per line:  DATE \x01 HASH \x01 EMAIL \x01 TYPE \x01 FULL_MESSAGE
#
# FULL_MESSAGE format: subject + "\n" + body (if body exists)
collect_commits() {
  local author_args=() merge_flag=()
  for e in "${AUTHORS[@]}"; do author_args+=(--author="$e"); done
  $INCLUDE_MERGES || merge_flag=(--no-merges)

  # Single git log call; %B gives full message (subject + body)
  # We use %s for subject and %b for body to process them separately
  git log --all \
    "${author_args[@]}" \
    --since="${DAYS} days ago" \
    --pretty=format:"%ad%x01%h%x01%ae%x01%s%x01%b" \
    --date=short \
    "${merge_flag[@]}" \
    2>/dev/null \
  | awk 'BEGIN { FS="\001"; OFS="\001" }
    {
      date=$1; hash=$2; email=$3; subject=$4; body=$5

      # Combine subject and body
      s = subject
      if (length(body) > 0) {
        s = s "\n" body
      }

      # ── Extract conventional commit type ─────────────────────────────────
      # Matches: feat:  fix(scope):  chore!:  etc.
      type = "other"
      if (match(s, /^[a-z]+(\([^)]*\))?!?[[:space:]]*:/)) {
        prefix = substr(s, RSTART, RLENGTH)
        sub(/(\([^)]*\))?!?[[:space:]]*:/, "", prefix)  # isolate type word
        known = " feat fix chore docs style refactor test build ci perf revert "
        if (index(known, " " prefix " ") > 0) type = prefix
        # Strip the prefix from subject
        sub(/^[a-z]+(\([^)]*\))?!?[[:space:]]*:[[:space:]]*/, "", s)
      }

      # ── Strip ticket / issue prefixes ─────────────────────────────────────
      # [PROJ-123]  PROJ-123:  #42
      sub(/^\[?[A-Z]+-[0-9]+\]?[[:space:]:\/\-]*/, "", s)
      sub(/^#[0-9]+[[:space:]]*/, "", s)

      # ── Normalise whitespace (preserve newlines) ──────────────────────────
      # Only clean up leading/trailing whitespace, keep internal newlines
      sub(/^[[:space:]\n]+/, "", s)
      sub(/[[:space:]\n]+$/, "", s)

      # Collapse multiple spaces but preserve newlines
      gsub(/[[:space:]]+/, " ", s)
      gsub(/\n[[:space:]]+/, "\n", s)
      gsub(/[[:space:]]+\n/, "\n", s)

      # ── Title-case first letter ───────────────────────────────────────────
      if (length(s) > 0) {
        first_char = substr(s, 1, 1)
        if (first_char ~ /[a-z]/) {
          s = toupper(first_char) substr(s, 2)
        }
      }

      print date, hash, email, type, s
    }'
}

# ── Merge count (stats only — separate query to keep main log clean) ──────────
count_merges() {
  local author_args=()
  for e in "${AUTHORS[@]}"; do author_args+=(--author="$e"); done
  git log --all "${author_args[@]}" --since="${DAYS} days ago" \
    --merges --oneline 2>/dev/null | wc -l | tr -d ' '
}

# ── Portable weekday name  (Linux: date -d;  macOS: date -jf) ─────────────────
weekday_for() {  # $1 = YYYY-MM-DD
  date -d "$1" +"%A" 2>/dev/null \
  || date -jf "%Y-%m-%d" "$1" +"%A" 2>/dev/null \
  || printf ''
}

# ── Format message for display (handle multi-line) ────────────────────────────
format_message_display() {
  local msg="$1"
  local first_line=true
  while IFS= read -r line; do
    if $first_line; then
      printf '%s' "$line"
      first_line=false
    else
      printf '\n                      %s' "$line"
    fi
  done <<< "$msg"
}

# ── Shared stats footer ───────────────────────────────────────────────────────
print_stats() {
  local data="$1"
  local total active_days avg
  total=$(awk 'END{print NR}' <<< "$data")
  active_days=$(awk -F'\001' '{print $1}' <<< "$data" | sort -u | wc -l | tr -d ' ')
  # Division-by-zero guard: should never be zero if data is non-empty, but be safe
  if (( active_days > 0 )); then
    avg=$(awk "BEGIN{ printf \"%.1f\", $total / $active_days }")
  else
    avg="0.0"
  fi
  printf '%s  ──────────────────────────────────────────────────────%s\n' "${B}${C}" "${Rs}"
  printf '  %sTotal commits :%s %s%s%s\n'  "${Gy}" "${Rs}" "${B}" "$total"        "${Rs}"
  printf '  %sActive days   :%s %s / %s\n' "${Gy}" "${Rs}" "$active_days"  "$DAYS"
  printf '  %sAvg per day   :%s %s\n'      "${Gy}" "${Rs}" "$avg"
  printf '\n'
}

# ── Render: terminal — group by DAY ──────────────────────────────────────────
render_terminal_day() {
  local data="$1"
  local total first_date last_date mc
  total=$(awk 'END{print NR}' <<< "$data")
  first_date=$(awk -F'\001' 'END{print $1}'  <<< "$data")
  last_date=$(awk  -F'\001' 'NR==1{print $1}' <<< "$data")
  mc=$(count_merges)
  local multi=0; (( ${#AUTHORS[@]} > 1 )) && multi=1 || true
  local repo_name; repo_name=$(basename "$(git rev-parse --show-toplevel)")

  printf '%s╔══════════════════════════════════════════════════════╗%s\n' "${B}${C}" "${Rs}"
  printf '%s║              GIT TIMESHEET REPORT                   ║%s\n' "${B}${C}" "${Rs}"
  printf '%s╚══════════════════════════════════════════════════════╝%s\n' "${B}${C}" "${Rs}"
  printf '  %sRepo   :%s %s%s%s\n'   "${Gy}" "${Rs}" "${B}" "$repo_name" "${Rs}"
  printf '  %sAuthor :%s %s\n'       "${Gy}" "${Rs}" "$(IFS=', '; printf '%s' "${AUTHORS[*]}")"
  printf '  %sPeriod :%s %s → %s  (last %s days)\n' \
    "${Gy}" "${Rs}" "$first_date" "$last_date" "$DAYS"
  printf '  %sTotals :%s %s%s%s commits | %s merges\n\n' \
    "${Gy}" "${Rs}" "${B}" "$total" "${Rs}" "$mc"

  local cur_date="" day_count=0 wd
  while IFS=$'\001' read -r date hash email type msg; do
    if [[ "$date" != "$cur_date" ]]; then
      [[ -n "$cur_date" ]] && printf '  %s└─ %d commit(s)%s\n\n' "${Gy}" "$day_count" "${Rs}"
      wd=$(weekday_for "$date")
      printf '%s  %s  %s%s\n' "${B}${Gr}" "$date" "$wd" "${Rs}"
      printf '  %s──────────────────────────────────────%s\n' "${Gy}" "${Rs}"
      cur_date="$date"; day_count=0
    fi
    day_count=$(( day_count + 1 ))
    local tag=""
    (( multi )) && tag=" ${Gy}[${email}]${Rs}"

    # Display message with proper indentation for multi-line
    printf '  %s•%s %s[%s]%s%s ' "${Y}" "${Rs}" "${Gy}" "$hash" "${Rs}" "$tag"
    local first_line=true
    while IFS= read -r line; do
      if $first_line; then
        printf '%s\n' "$line"
        first_line=false
      else
        printf '                      %s\n' "$line"
      fi
    done <<< "$msg"
  done <<< "$data"
  [[ -n "$cur_date" ]] && printf '  %s└─ %d commit(s)%s\n\n' "${Gy}" "$day_count" "${Rs}"

  $SHOW_STATS && print_stats "$data"
}

# ── Render: terminal — group by COMMIT TYPE ───────────────────────────────────
render_terminal_type() {
  local data="$1"
  local multi=0; (( ${#AUTHORS[@]} > 1 )) && multi=1 || true
  local repo_name mc total
  repo_name=$(basename "$(git rev-parse --show-toplevel)")
  mc=$(count_merges)
  total=$(awk 'END{print NR}' <<< "$data")

  printf '%s╔══════════════════════════════════════════════════════╗%s\n' "${B}${C}" "${Rs}"
  printf '%s║          GIT TIMESHEET REPORT  (by type)            ║%s\n' "${B}${C}" "${Rs}"
  printf '%s╚══════════════════════════════════════════════════════╝%s\n' "${B}${C}" "${Rs}"
  printf '  %sRepo   :%s %s%s%s\n'  "${Gy}" "${Rs}" "${B}" "$repo_name" "${Rs}"
  printf '  %sAuthor :%s %s\n'      "${Gy}" "${Rs}" "$(IFS=', '; printf '%s' "${AUTHORS[*]}")"
  printf '  %sTotals :%s %s%s%s commits | %s merges\n' \
    "${Gy}" "${Rs}" "${B}" "$total" "${Rs}" "$mc"

  # Collect unique types in order of first appearance
  local types=()
  while IFS= read -r t; do types+=("$t"); done \
    < <(awk -F'\001' '{print $4}' <<< "$data" | awk '!seen[$0]++')

  for t in "${types[@]}"; do
    local label="${TYPE_LABELS[$t]:-📌 Other}"
    local count; count=$(awk -F'\001' -v tp="$t" '$4==tp{c++} END{print c+0}' <<< "$data")
    printf '\n%s  %s%s  %s(%s)%s\n' "${B}${Y}" "$label" "${Rs}" "${Gy}" "$count" "${Rs}"
    printf '  %s──────────────────────────────────────%s\n' "${Gy}" "${Rs}"
    # Filter to just this type
    while IFS=$'\001' read -r date hash email type msg; do
      local tag=""
      (( multi )) && tag=" ${Gy}[${email}]${Rs}"
      printf '  %s•%s %s[%s]%s%s ' "${Y}" "${Rs}" "${Gy}" "$hash" "${Rs}" "$tag"
      local first_line=true
      while IFS= read -r line; do
        if $first_line; then
          printf '%s  %s(%s)%s\n' "$line" "${Gy}" "$date" "${Rs}"
          first_line=false
        else
          printf '                      %s\n' "$line"
        fi
      done <<< "$msg"
    done < <(awk -F'\001' -v tp="$t" '$4==tp' <<< "$data")
  done
  printf '\n'

  $SHOW_STATS && print_stats "$data"
}

# ── Render: JSON ──────────────────────────────────────────────────────────────
render_json() {
  local data="$1"
  local repo_name first_date last_date total active_days avg
  repo_name=$(basename "$(git rev-parse --show-toplevel)")
  first_date=$(awk -F'\001' 'END{print $1}'   <<< "$data")
  last_date=$(awk  -F'\001' 'NR==1{print $1}' <<< "$data")
  total=$(awk 'END{print NR}' <<< "$data")
  active_days=$(awk -F'\001' '{print $1}' <<< "$data" | sort -u | wc -l | tr -d ' ')
  (( active_days > 0 )) \
    && avg=$(awk "BEGIN{ printf \"%.1f\", $total / $active_days }") \
    || avg="0.0"

  # Build JSON authors array
  local authors_json=""
  for e in "${AUTHORS[@]}"; do authors_json+="\"${e}\","; done
  authors_json="[${authors_json%,}]"

  printf '{\n'
  printf '  "repo": "%s",\n'         "$repo_name"
  printf '  "authors": %s,\n'        "$authors_json"
  printf '  "days": %s,\n'           "$DAYS"
  printf '  "first_date": "%s",\n'   "$first_date"
  printf '  "last_date": "%s",\n'    "$last_date"
  printf '  "total_commits": %s,\n'  "$total"
  printf '  "active_days": %s,\n'    "$active_days"
  printf '  "avg_per_day": %s,\n'    "$avg"
  printf '  "commits": [\n'

  local first_entry=true
  while IFS=$'\001' read -r date hash email type msg; do
    $first_entry || printf ',\n'
    first_entry=false
    # Proper JSON escaping: backslash, quotes, and newlines
    local safe
    safe=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    printf '    {"date":"%s","hash":"%s","author":"%s","type":"%s","subject":"%s"}' \
      "$date" "$hash" "$email" "$type" "$safe"
  done <<< "$data"

  printf '\n  ]\n}\n'
}

# ── Render: CSV ───────────────────────────────────────────────────────────────
render_csv() {
  printf '"date","hash","author","type","subject"\n'
  # Handle multi-line messages by replacing newlines with spaces for CSV
  awk -F'\001' '{
    gsub(/"/, "\"\"", $5)   # RFC 4180: double-up embedded quotes
    gsub(/\n/, " ", $5)     # Replace newlines with spaces for CSV
    gsub(/[[:space:]]+/, " ", $5)  # Normalize spaces
    printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", $1, $2, $3, $4, $5
  }' <<< "$1"
}

# ── Render: Markdown ──────────────────────────────────────────────────────────
render_md() {
  local data="$1"
  local repo_name total active_days avg
  repo_name=$(basename "$(git rev-parse --show-toplevel)")
  total=$(awk 'END{print NR}' <<< "$data")
  active_days=$(awk -F'\001' '{print $1}' <<< "$data" | sort -u | wc -l | tr -d ' ')
  (( active_days > 0 )) \
    && avg=$(awk "BEGIN{ printf \"%.1f\", $total / $active_days }") \
    || avg="0.0"

  printf '# Git Timesheet — %s\n\n' "$repo_name"
  printf '**Author(s):** %s  \n'     "$(IFS=', '; printf '%s' "${AUTHORS[*]}")"
  printf '**Period:** last %s days  \n' "$DAYS"
  printf '**Commits:** %s | **Active days:** %s / %s | **Avg/day:** %s\n\n' \
    "$total" "$active_days" "$DAYS" "$avg"
  printf '---\n\n'

  if [[ "$GROUP_BY" == "type" ]]; then
    local types=()
    while IFS= read -r t; do types+=("$t"); done \
      < <(awk -F'\001' '{print $4}' <<< "$data" | awk '!seen[$0]++')
    for t in "${types[@]}"; do
      local label="${TYPE_LABELS[$t]:-Other}"
      printf '## %s\n\n' "$label"
      while IFS=$'\001' read -r date hash email type msg; do
        # Replace newlines with <br> for markdown
        local md_msg; md_msg=$(printf '%s' "$msg" | sed 's/$/<br>/' | tr -d '\n' | sed 's/<br>$//')
        printf -- '- `%s` **%s** *(by %s — %s)*\n' "$hash" "$md_msg" "$email" "$date"
      done < <(awk -F'\001' -v tp="$t" '$4==tp' <<< "$data")
      printf '\n'
    done
  else
    local cur_date="" wd
    while IFS=$'\001' read -r date hash email type msg; do
      if [[ "$date" != "$cur_date" ]]; then
        [[ -n "$cur_date" ]] && printf '\n'
        wd=$(weekday_for "$date")
        printf '## %s — %s\n\n' "$date" "$wd"
        cur_date="$date"
      fi
      # Replace newlines with <br> for markdown
      local md_msg; md_msg=$(printf '%s' "$msg" | sed 's/$/<br>/' | tr -d '\n' | sed 's/<br>$//')
      printf -- '- `%s` **%s** *(by %s — %s)*\n' "$hash" "$md_msg" "$email" "$type"
    done <<< "$data"
    printf '\n'
  fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  validate
  init_colors

  # Banner + confirmation only for interactive terminal output
  if [[ "$FORMAT" == "terminal" ]]; then
    repo_banner
    confirm_or_exit
  fi

  local data
  data=$(collect_commits)

  if [[ -z "$data" ]]; then
    local who; who=$(IFS=', '; printf '%s' "${AUTHORS[*]}")
    printf '%sNo commits found for [%s] in the last %s days.%s\n' \
      "${Y}" "$who" "$DAYS" "${Rs}"
    exit 0
  fi

  case "$FORMAT" in
    terminal)
      case "$GROUP_BY" in
        day)  render_terminal_day  "$data" ;;
        type) render_terminal_type "$data" ;;
      esac ;;
    json) render_json "$data" ;;
    csv)  render_csv  "$data" ;;
    md)   render_md   "$data" ;;
  esac
}

main "$@"
