//! `digiclean` — command-line duplicate finder built on the same engine as
//! the app. Read-only: it reports duplicates but never modifies files.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use digiclean_engine::report::{self, ReportClock, ReportFormat};
use digiclean_engine::session::{GroupFilter, SortKey};
use digiclean_engine::{
    run_scan, FileCategory, HashAlgorithm, HashCache, Performance, ProgressSnapshot, ScanConfig,
    ScanControl, Session,
};

#[derive(Parser)]
#[command(
    name = "digiclean",
    version,
    about = "Find duplicate files and folders by content"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

// Parsed once per run; the size of the largest variant does not matter.
#[allow(clippy::large_enum_variant)]
#[derive(Subcommand)]
enum Command {
    /// Scan folders and report duplicates.
    Scan(ScanArgs),
    /// Run a background check written by the app: scan its locations, save
    /// the results for it, and show a notification when there is something
    /// to clean up. Never removes anything.
    Check {
        /// Job file written by the app.
        #[arg(long)]
        job: PathBuf,
        /// Print the summary only; do not show a notification.
        #[arg(long)]
        no_notify: bool,
    },
    /// Manage the hash cache.
    Cache {
        #[arg(long)]
        dir: PathBuf,
        #[command(subcommand)]
        action: CacheAction,
    },
}

#[derive(Subcommand)]
enum CacheAction {
    Stats,
    Clear,
    /// Remove entries not seen for N days.
    Prune {
        days: u32,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Algo {
    Blake3,
    Sha256,
}

#[derive(Clone, Copy, ValueEnum)]
enum Perf {
    Max,
    Balanced,
    Battery,
    Hdd,
}

#[derive(clap::Args)]
struct ScanArgs {
    /// Folders to scan.
    #[arg(required = true)]
    paths: Vec<PathBuf>,
    /// Minimum file size (e.g. 1, 10K, 5M, 1G).
    #[arg(long, default_value = "1", value_parser = parse_size)]
    min_size: u64,
    #[arg(long, value_parser = parse_size)]
    max_size: Option<u64>,
    /// Only these extensions (comma separated).
    #[arg(long, value_delimiter = ',')]
    ext: Vec<String>,
    /// Skip these extensions (comma separated).
    #[arg(long, value_delimiter = ',')]
    skip_ext: Vec<String>,
    /// Only these categories: image, video, audio, document, archive, application, other.
    #[arg(long, value_delimiter = ',')]
    category: Vec<String>,
    /// Folders to skip.
    #[arg(long)]
    exclude: Vec<PathBuf>,
    /// Glob patterns to skip, e.g. "**/node_modules".
    #[arg(long)]
    glob: Vec<String>,
    #[arg(long)]
    hidden: bool,
    #[arg(long)]
    no_recursive: bool,
    #[arg(long)]
    depth: Option<u32>,
    #[arg(long)]
    follow_symlinks: bool,
    #[arg(long, value_enum, default_value = "blake3")]
    algo: Algo,
    /// Confirm every duplicate byte-by-byte.
    #[arg(long)]
    verify: bool,
    #[arg(long)]
    no_folders: bool,
    #[arg(long)]
    empty_files: bool,
    #[arg(long, value_enum, default_value = "balanced")]
    performance: Perf,
    #[arg(long, default_value_t = 0)]
    threads: u32,
    /// Directory for the persistent hash cache.
    #[arg(long)]
    cache: Option<PathBuf>,
    /// Print JSON instead of text.
    #[arg(long)]
    json: bool,
    /// Also write a report; the format follows the extension (.csv, .json,
    /// .html). Dates are in UTC.
    #[arg(long, value_name = "FILE")]
    export: Option<PathBuf>,
    /// Maximum groups to print in text mode.
    #[arg(long, default_value_t = 25)]
    limit: usize,
    #[arg(long, short)]
    quiet: bool,
}

fn parse_size(s: &str) -> Result<u64, String> {
    let s = s.trim().to_uppercase();
    let (num, mult) = match s.chars().last() {
        Some('K') => (&s[..s.len() - 1], 1u64 << 10),
        Some('M') => (&s[..s.len() - 1], 1 << 20),
        Some('G') => (&s[..s.len() - 1], 1 << 30),
        Some('T') => (&s[..s.len() - 1], 1 << 40),
        _ => (s.as_str(), 1),
    };
    num.trim()
        .parse::<f64>()
        .map(|n| (n * mult as f64) as u64)
        .map_err(|_| format!("invalid size '{s}'"))
}

fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

fn category(name: &str) -> Result<FileCategory> {
    Ok(match name.trim().to_lowercase().as_str() {
        "image" | "images" => FileCategory::Image,
        "video" | "videos" => FileCategory::Video,
        "audio" | "music" => FileCategory::Audio,
        "document" | "documents" | "docs" => FileCategory::Document,
        "archive" | "archives" => FileCategory::Archive,
        "application" | "applications" | "apps" => FileCategory::Application,
        "other" => FileCategory::Other,
        other => anyhow::bail!("unknown category '{other}'"),
    })
}

fn scan(args: ScanArgs) -> Result<()> {
    let cfg = ScanConfig {
        roots: args.paths,
        recursive: !args.no_recursive,
        max_depth: args.depth,
        follow_symlinks: args.follow_symlinks,
        include_hidden: args.hidden,
        min_size: args.min_size,
        max_size: args.max_size,
        include_extensions: args.ext,
        exclude_extensions: args.skip_ext,
        categories: args
            .category
            .iter()
            .map(|c| category(c))
            .collect::<Result<_>>()?,
        exclude_paths: args.exclude,
        exclude_globs: args.glob,
        hash_algorithm: match args.algo {
            Algo::Blake3 => HashAlgorithm::Blake3,
            Algo::Sha256 => HashAlgorithm::Sha256,
        },
        verify_byte_by_byte: args.verify,
        detect_duplicate_folders: !args.no_folders,
        include_empty_files: args.empty_files,
        performance: match args.performance {
            Perf::Max => Performance::Maximum,
            Perf::Balanced => Performance::Balanced,
            Perf::Battery => Performance::BatterySaver,
            Perf::Hdd => Performance::SpinningDisk,
        },
        threads: args.threads,
        cache_dir: args.cache,
        ..Default::default()
    };

    // Read-only tool: Ctrl+C simply terminates the process.
    let control = ScanControl::new();
    let sink: Option<Arc<dyn digiclean_engine::ProgressSink>> = if args.quiet || args.json {
        None
    } else {
        Some(Arc::new(|p: &ProgressSnapshot| {
            let pct = (p.phase_bytes_done * 100)
                .checked_div(p.phase_bytes_total)
                .map(|v| format!(" {v:>3}%"))
                .unwrap_or_default();
            eprint!(
                "\r\x1b[2K{}{} · {} files · {}/s",
                p.phase.label(),
                pct,
                p.files_discovered,
                human(p.bytes_per_second)
            );
        }))
    };

    let result = run_scan(&cfg, &control, sink).context("scan failed")?;
    if !args.quiet && !args.json {
        eprintln!();
    }
    let session = Session::new(result);
    let stats = &session.result.stats;
    let filter = GroupFilter::default();

    if let Some(path) = &args.export {
        let format = path
            .extension()
            .and_then(|e| e.to_str())
            .and_then(ReportFormat::from_extension)
            .context("--export needs a .csv, .json or .html file name")?;
        let clock = ReportClock {
            now_ms: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0),
            utc_offset_min: 0,
        };
        std::fs::write(path, report::render(&session, format, clock))
            .with_context(|| format!("writing {}", path.display()))?;
        if !args.quiet && !args.json {
            eprintln!("Report written to {}", path.display());
        }
    }

    if args.json {
        let files = session.file_groups(0, usize::MAX, SortKey::Wasted, true, &filter);
        let folders = session.folder_groups(0, usize::MAX, SortKey::Wasted, true, &filter);
        let empty = session.empty_folders(0, usize::MAX, SortKey::Path, false, &filter);
        let json = serde_json::json!({
            "stats": stats,
            "file_groups": files.items.iter().map(|g| serde_json::json!({
                "size": g.size,
                "hash": g.digest,
                "category": g.category,
                "paths": g.items.iter().map(|i| i.path.to_string_lossy()).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
            "folder_groups": folders.items.iter().map(|g| serde_json::json!({
                "size": g.total_bytes,
                "files": g.file_count,
                "paths": g.items.iter().map(|i| i.path.to_string_lossy()).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
            "empty_folders": empty.items.iter().map(|i| i.path.to_string_lossy()).collect::<Vec<_>>(),
            "junk": session.junk(0, usize::MAX, SortKey::Size, true, &filter).items.iter().map(|j| serde_json::json!({
                "path": j.path.to_string_lossy(),
                "kind": j.kind,
                "size": j.size,
            })).collect::<Vec<_>>(),
            "issues": session.result.issues,
        });
        println!("{}", serde_json::to_string_pretty(&json)?);
        return Ok(());
    }

    println!(
        "Scanned {} files ({}) in {:.2}s — {} hashed, {} from cache",
        stats.files_seen,
        human(stats.bytes_seen),
        Duration::from_millis(stats.elapsed_ms).as_secs_f64(),
        stats.files_fully_hashed,
        stats.cache_hits
    );
    println!(
        "{} duplicate groups, {} extra copies, {} reclaimable",
        stats.duplicate_groups,
        stats.duplicate_files,
        human(stats.wasted_bytes)
    );
    let files = session.file_groups(0, args.limit, SortKey::Wasted, true, &filter);
    for g in &files.items {
        println!(
            "\n{} × {} ({} wasted)",
            g.items.len(),
            human(g.size),
            human(g.wasted)
        );
        for item in &g.items {
            println!("    {}", item.path.display());
        }
    }
    if files.total > files.items.len() {
        println!(
            "\n… {} more groups (use --limit or --json)",
            files.total - files.items.len()
        );
    }

    let folders = session.folder_groups(0, args.limit, SortKey::Wasted, true, &filter);
    if folders.total > 0 {
        println!(
            "\n{} duplicate folder groups, {} reclaimable",
            stats.folder_groups,
            human(stats.folder_wasted_bytes)
        );
        for g in &folders.items {
            println!(
                "\n[folder] {} files, {}",
                g.file_count,
                human(g.total_bytes)
            );
            for item in &g.items {
                println!("    {}", item.path.display());
            }
        }
    }
    if stats.empty_folders > 0 {
        println!("\n{} empty folders", stats.empty_folders);
    }
    if stats.junk_items > 0 {
        println!(
            "\n{} junk items ({}): caches, unfinished downloads, temporary and empty files, broken links",
            stats.junk_items,
            human(stats.junk_bytes)
        );
    }
    if stats.errors > 0 {
        println!("\n{} items could not be read:", stats.errors);
        for issue in session.result.issues.iter().take(10) {
            println!("    {} — {}", issue.path, issue.message);
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Scan(args) => scan(args),
        Command::Check { job, no_notify } => {
            let text = std::fs::read_to_string(&job)
                .with_context(|| format!("reading {}", job.display()))?;
            let job: digiclean_engine::background::CheckJob =
                serde_json::from_str(&text).context("invalid job file")?;
            let result = digiclean_engine::background::run_check(&job, &ScanControl::new())
                .context("background check failed")?;
            println!("{}", serde_json::to_string_pretty(&result)?);
            if let (Some(notice), false) = (&result.notice, no_notify) {
                if let Err(e) = digiclean_engine::background::notify(notice) {
                    eprintln!("notification not shown: {e}");
                }
            }
            Ok(())
        }
        Command::Cache { dir, action } => {
            let cache = HashCache::open(&dir)?;
            match action {
                CacheAction::Stats => println!(
                    "{} entries, {} on disk ({})",
                    cache.entry_count(),
                    human(cache.size_on_disk()),
                    cache.path().display()
                ),
                CacheAction::Clear => {
                    cache.clear()?;
                    println!("cache cleared");
                }
                CacheAction::Prune { days } => println!("removed {} entries", cache.prune(days)?),
            }
            Ok(())
        }
    }
}
