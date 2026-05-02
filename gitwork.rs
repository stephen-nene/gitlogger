use std::process::{Command, exit};
use std::path::PathBuf;
use serde::{Serialize, Deserialize};
use clap::{Parser, ValueEnum};

#[derive(Debug, Clone, ValueEnum)]
enum OutputMode {
    Pretty,
    Oneline,
    Full,
    Stat,
    Diff,
    Files,
    Json,
    Csv,
    Summary,
}

#[derive(Parser, Debug)]
#[command(name = "gitwork")]
#[command(about = "Git commit analyzer with time shortcuts", long_about = None)]
struct Args {
    /// Time shortcut (today, yesterday, week, month, monday, 3d, 7d, etc)
    time: Option<String>,

    /// Since date/time
    #[arg(long)]
    since: Option<String>,

    /// Until date/time
    #[arg(long)]
    until: Option<String>,

    /// Comma-separated author emails
    #[arg(long)]
    authors: Option<String>,

    /// Include yourself (git config user.email)
    #[arg(long)]
    me: bool,

    /// Show all authors
    #[arg(long)]
    all: bool,

    /// Output mode
    #[arg(long, value_enum, default_value = "pretty")]
    mode: OutputMode,

    /// Oneline output
    #[arg(long)]
    oneline: bool,

    /// Full output
    #[arg(long)]
    full: bool,

    /// Stat output
    #[arg(long)]
    stat: bool,

    /// Diff output
    #[arg(long)]
    diff: bool,

    /// Files only
    #[arg(long)]
    files: bool,

    /// JSON output
    #[arg(long)]
    json: bool,

    /// CSV output
    #[arg(long)]
    csv: bool,

    /// Summary statistics
    #[arg(long)]
    summary: bool,

    /// Exclude merge commits
    #[arg(long)]
    no_merges: bool,

    /// Only merge commits
    #[arg(long)]
    only_merges: bool,

    /// Repository directory
    #[arg(long, default_value = ".")]
    path: PathBuf,

    /// Limit to subdirectory within repo
    #[arg(long)]
    file_path: Option<String>,

    /// Filter by commit message (can be used multiple times)
    #[arg(long)]
    grep: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Commit {
    hash: String,
    author: String,
    email: String,
    date: String,
    subject: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    body: String,
}

fn main() {
    let mut args = Args::parse();

    // Determine output mode from flags
    if args.json {
        args.mode = OutputMode::Json;
    } else if args.csv {
        args.mode = OutputMode::Csv;
    } else if args.summary {
        args.mode = OutputMode::Summary;
    } else if args.oneline {
        args.mode = OutputMode::Oneline;
    } else if args.full {
        args.mode = OutputMode::Full;
    } else if args.stat {
        args.mode = OutputMode::Stat;
    } else if args.diff {
        args.mode = OutputMode::Diff;
    } else if args.files {
        args.mode = OutputMode::Files;
    }

    // Validate repository
    if !validate_repo(&args.path) {
        eprintln!("❌ Not a git repository: {}", args.path.display());
        exit(1);
    }

    // Parse time shortcut
    let since = if let Some(time) = &args.time {
        Some(parse_time_shortcut(time))
    } else {
        args.since.clone()
    };

    // Build author list
    let mut authors = Vec::new();
    let mut explicit_author = false;

    if let Some(author_str) = &args.authors {
        explicit_author = true;
        for email in author_str.split(',') {
            let email = email.trim();
            if !email.is_empty() {
                authors.push(email.to_string());
            }
        }
    }

    if args.me {
        explicit_author = true;
        if let Some(email) = get_git_config(&args.path, "user.email") {
            authors.push(email);
        }
    }

    if args.all {
        explicit_author = true;
        authors.clear();
    }

    // Default to --me if no explicit author
    if !explicit_author {
        if let Some(email) = get_git_config(&args.path, "user.email") {
            authors.push(email);
        }
    }

    // Fetch commits
    let commits = fetch_commits(
        &args.path,
        since.as_deref(),
        args.until.as_deref(),
        &authors,
        args.no_merges,
        args.only_merges,
        args.file_path.as_deref(),
        &args.grep,
    );

    // Output
    match args.mode {
        OutputMode::Json => output_json(&commits),
        OutputMode::Csv => output_csv(&commits),
        OutputMode::Summary => output_summary(&commits),
        OutputMode::Pretty => output_pretty(&commits),
        _ => output_pretty(&commits),
    }
}

fn parse_time_shortcut(shortcut: &str) -> String {
    match shortcut {
        "today" => "midnight".to_string(),
        "yesterday" => "yesterday".to_string(),
        "week" => "1 week ago".to_string(),
        "month" => "1 month ago".to_string(),
        "monday" => "last Monday".to_string(),
        s if s.ends_with('d') => format!("{} days ago", &s[..s.len() - 1]),
        s if s.ends_with('w') => format!("{} weeks ago", &s[..s.len() - 1]),
        s if s.ends_with('m') => format!("{} months ago", &s[..s.len() - 1]),
        s => s.to_string(),
    }
}

fn validate_repo(path: &PathBuf) -> bool {
    Command::new("git")
        .args(["-C", path.to_str().unwrap(), "rev-parse", "--is-inside-work-tree"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn get_git_config(path: &PathBuf, key: &str) -> Option<String> {
    Command::new("git")
        .args(["-C", path.to_str().unwrap(), "config", key])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout).ok().map(|s| s.trim().to_string())
            } else {
                None
            }
        })
}

fn fetch_commits(
    repo_dir: &PathBuf,
    since: Option<&str>,
    until: Option<&str>,
    authors: &[String],
    no_merges: bool,
    only_merges: bool,
    file_path: Option<&str>,
    grep_patterns: &[String],
) -> Vec<Commit> {
    let mut cmd = Command::new("git");
    cmd.args(["-C", repo_dir.to_str().unwrap(), "log"]);
    cmd.arg("--pretty=format:%H\x1F%an\x1F%ae\x1F%aI\x1F%s\x1F%b\x1E");

    if let Some(s) = since {
        cmd.arg(format!("--since={}", s));
    }
    if let Some(u) = until {
        cmd.arg(format!("--until={}", u));
    }
    if no_merges {
        cmd.arg("--no-merges");
    }
    if only_merges {
        cmd.arg("--merges");
    }
    for author in authors {
        cmd.arg(format!("--author={}", author));
    }
    for pattern in grep_patterns {
        cmd.arg(format!("--grep={}", pattern));
    }
    if let Some(fp) = file_path {
        cmd.args(["--", fp]);
    }

    let output = cmd.output().expect("Failed to execute git log");
    let stdout = String::from_utf8_lossy(&output.stdout);

    let mut commits = Vec::new();
    for record in stdout.split('\x1E') {
        let record = record.trim();
        if record.is_empty() {
            continue;
        }
        let fields: Vec<&str> = record.split('\x1F').collect();
        if fields.len() < 5 {
            continue;
        }
        commits.push(Commit {
            hash: fields[0][..7.min(fields[0].len())].to_string(),
            author: fields[1].to_string(),
            email: fields[2].to_string(),
            date: fields[3].to_string(),
            subject: fields[4].to_string(),
            body: if fields.len() > 5 {
                fields[5].trim().to_string()
            } else {
                String::new()
            },
        });
    }
    commits
}

fn output_json(commits: &[Commit]) {
    println!("{}", serde_json::to_string_pretty(commits).unwrap());
}

fn output_csv(commits: &[Commit]) {
    println!("hash,author,date,subject");
    for c in commits {
        println!("{},{},{},{}", c.hash, c.author, c.date, c.subject);
    }
}

fn output_summary(commits: &[Commit]) {
    println!("{:<18} {}", "Total commits:", commits.len());
}

fn output_pretty(commits: &[Commit]) {
    let mut prev_date = String::new();
    for c in commits {
        let date = &c.date[..10];
        if date != prev_date {
            if !prev_date.is_empty() {
                println!();
            }
            println!("\n📅 \x1b[1;36m{}\x1b[0m", date);
            prev_date = date.to_string();
        }
        println!("  • \x1b[1;33m{}\x1b[0m {}", c.hash, c.subject);
        if !c.body.is_empty() {
            for line in c.body.lines() {
                let line = line.trim();
                if !line.is_empty() {
                    println!("    \x1b[90m{}\x1b[0m", line);
                }
            }
        }
    }
}
