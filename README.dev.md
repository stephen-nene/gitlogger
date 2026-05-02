# gitwork - Multi-language Git Commit Analyzer

Git commit analyzer with time shortcuts and multiple output formats, implemented in Bash, Go, Python, and Rust.

## Features

- **Time shortcuts**: `today`, `yesterday`, `week`, `month`, `monday`, `3d`, `7d`, `2w`, `1m`
- **Author filtering**: Single, multiple, or all authors
- **Output formats**: Pretty (default), JSON, CSV, summary
- **Commit body support**: Shows full commit messages with bullet points
- **Repository targeting**: Analyze any git repository with `--path`

## Installation & Usage

### Bash (gitwork.sh)

**Requirements**: bash 4.0+, git

```bash
chmod +x gitwork.sh

# Usage
./gitwork.sh today
./gitwork.sh week --authors alice@co.com
./gitwork.sh month --json --all
./gitwork.sh week --path ~/projects/api
```

### Go (gitwork.go)

**Requirements**: Go 1.16+

```bash
# Build
go build -o gitwork gitwork.go

# Usage
./gitwork today
./gitwork week -authors alice@co.com
./gitwork month -json -all
./gitwork week -path ~/projects/api
```

### Python (gitwork.py)

**Requirements**: Python 3.7+

```bash
chmod +x gitwork.py

# Usage
./gitwork.py today
./gitwork.py week --authors alice@co.com
./gitwork.py month --json --all
./gitwork.py week --path ~/projects/api
```

### Rust (gitwork.rs)

**Requirements**: Rust 1.70+

```bash
# Build
cargo build --release
# Binary will be in target/release/gitwork

# Or run directly
cargo run -- today
cargo run -- week --authors alice@co.com
cargo run -- month --json --all
cargo run -- week --path ~/projects/api
```

## Command Reference

### Time Shortcuts (First Argument)

```bash
today          # Since midnight
yesterday      # Since yesterday 00:00
week           # Since 1 week ago
month          # Since 1 month ago
monday         # Since last Monday 00:00
3d             # Since 3 days ago
7d             # Since 7 days ago
2w             # Since 2 weeks ago
1m             # Since 1 month ago
```

### Author Options

```bash
--authors <emails>     # Comma-separated: alice@co.com,bob@co.com
--me                   # Include yourself (git config user.email)
--all                  # Show all authors (overrides default --me)
```

**Default behavior**: If no author flag is specified, defaults to `--me`

### Output Modes

```bash
--oneline              # Compact one line per commit
--full                 # Full commit message
--stat                 # Show files changed summary
--diff                 # Show full diffs
--files                # Only file names
--summary              # Print total commits
--json                 # Output as JSON array
--csv                  # Output as CSV
```

### Filters

```bash
--no-merges            # Exclude merge commits
--only-merges          # Only merge commits
--path <dir>           # Repository directory (absolute or relative)
--file-path <dir>      # Limit to subdirectory within repo
--grep <pattern>       # Filter by commit message
```

## Examples

### Basic Usage

```bash
# Your commits today
gitwork today

# Everyone's commits today
gitwork today --all

# Alice's commits this week
gitwork week --authors alice@co.com

# Alice + Bob + you
gitwork week --authors alice@co.com,bob@co.com --me
```

### Different Repositories

```bash
# Analyze a different repo
gitwork week --path ~/projects/api

# Relative path
gitwork month --path ../../Bima365
```

### Output Formats

```bash
# JSON export
gitwork month --json --all > commits.json

# CSV export
gitwork week --csv > commits.csv

# Summary statistics
gitwork 30d --summary --no-merges
```

### Advanced Filtering

```bash
# Non-merge commits since Monday
gitwork monday --no-merges

# Filter by commit message
gitwork week --grep "fix" --grep "bug"

# Specific subdirectory
gitwork month --file-path src/components
```

## Output Format

### Pretty Mode (Default)

```
📅 2026-04-29
  • 1558b0d refactor: clean up unused imports
    - Removed unused React imports
    - Fixed type definitions
  • d0d2169 Merge remote-tracking branch 'origin/steve'

📅 2026-04-24
  • 12b4bf1 feat: enhance user profile page
    - Added full name and initials generation
    - Included profile picture handling
```

### JSON Mode

```json
[
  {
    "hash": "1558b0d",
    "author": "Steve",
    "email": "steve@example.com",
    "date": "2026-04-29T10:30:00+03:00",
    "subject": "refactor: clean up unused imports",
    "body": "- Removed unused React imports\n- Fixed type definitions"
  }
]
```

### CSV Mode

```csv
hash,author,date,subject
1558b0d,Steve,2026-04-29T10:30:00+03:00,refactor: clean up unused imports
```

## Performance Comparison

| Language | Build Time | Binary Size | Execution Speed |
|----------|-----------|-------------|-----------------|
| Bash     | N/A       | ~15KB       | Fast            |
| Python   | N/A       | ~10KB       | Fast            |
| Go       | ~2s       | ~2MB        | Very Fast       |
| Rust     | ~30s      | ~3MB        | Very Fast       |

## License

MIT
