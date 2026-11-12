//! Reports of the current results, to share or audit before deleting:
//! CSV (one row per item, for spreadsheets), JSON (for scripts) and a
//! self-contained HTML page to read or print.
//!
//! Reports show what the results screen shows: groups hidden by the ignore
//! list and items already removed are left out, and every row says whether
//! it is selected for removal.

use std::fmt::Write as _;
use std::path::Path;

use crate::junk::JunkKind;
use crate::session::{
    FileGroupView, FileItem, FolderGroupView, FolderItem, GroupFilter, JunkItem, Session, SortKey,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReportFormat {
    Csv,
    Json,
    Html,
}

impl ReportFormat {
    /// From a file extension (`csv`, `json`, `html`/`htm`).
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_ascii_lowercase().as_str() {
            "csv" => Some(Self::Csv),
            "json" => Some(Self::Json),
            "html" | "htm" => Some(Self::Html),
            _ => None,
        }
    }
}

/// Groups shown in an HTML report per section; CSV and JSON list everything.
const HTML_GROUP_LIMIT: usize = 2_000;

/// Times in reports: `now_ms` is when the report is made, and
/// `utc_offset_min` the viewer's time zone (dates are written in local time).
#[derive(Clone, Copy, Debug)]
pub struct ReportClock {
    pub now_ms: i64,
    pub utc_offset_min: i32,
}

struct Contents {
    files: Vec<FileGroupView>,
    folders: Vec<FolderGroupView>,
    empty: Vec<FolderItem>,
    large: Vec<FileItem>,
    junk: Vec<JunkItem>,
}

fn contents(session: &Session) -> Contents {
    let all = GroupFilter::default();
    Contents {
        files: session
            .file_groups(0, usize::MAX, SortKey::Wasted, true, &all)
            .items,
        folders: session
            .folder_groups(0, usize::MAX, SortKey::Wasted, true, &all)
            .items,
        empty: session
            .empty_folders(0, usize::MAX, SortKey::Path, false, &all)
            .items,
        large: session
            .large_files(0, usize::MAX, SortKey::Size, true, &all)
            .items,
        junk: session.junk(0, usize::MAX, SortKey::Size, true, &all).items,
    }
}

/// Renders the report. Paths that are not valid Unicode are written lossily.
pub fn render(session: &Session, format: ReportFormat, clock: ReportClock) -> Vec<u8> {
    let c = contents(session);
    match format {
        ReportFormat::Csv => csv(&c, clock),
        ReportFormat::Json => json(session, &c, clock),
        ReportFormat::Html => html(session, &c, clock),
    }
    .into_bytes()
}

// ── CSV ────────────────────────────────────────────────────────────────

fn csv(c: &Contents, clock: ReportClock) -> String {
    // The byte-order mark makes Excel read the file as UTF-8.
    let mut out = String::from("\u{feff}section,group,path,size_bytes,modified,hash,selected\r\n");
    let mut row = |section: &str,
                   group: Option<usize>,
                   path: &Path,
                   size: u64,
                   modified_ns: i64,
                   hash: &str,
                   selected: bool| {
        let _ = write!(
            out,
            "{section},{},{},{size},{},{hash},{}\r\n",
            group.map(|g| g.to_string()).unwrap_or_default(),
            csv_field(&path.to_string_lossy()),
            local_time(modified_ns / 1_000_000, clock.utc_offset_min, true),
            if selected { "yes" } else { "no" },
        );
    };
    for (i, g) in c.files.iter().enumerate() {
        for f in &g.items {
            row(
                "duplicate_file",
                Some(i + 1),
                &f.path,
                g.size,
                f.modified_ns,
                &g.digest,
                f.selected,
            );
        }
    }
    for (i, g) in c.folders.iter().enumerate() {
        for d in &g.items {
            row(
                "duplicate_folder",
                Some(i + 1),
                &d.path,
                g.total_bytes,
                d.modified_ns,
                &g.digest,
                d.selected,
            );
        }
    }
    for d in &c.empty {
        row(
            "empty_folder",
            None,
            &d.path,
            0,
            d.modified_ns,
            "",
            d.selected,
        );
    }
    for j in &c.junk {
        row(
            junk_section(j.kind),
            None,
            &j.path,
            j.size,
            j.modified_ns,
            "",
            j.selected,
        );
    }
    for f in &c.large {
        row(
            "large_file",
            None,
            &f.path,
            f.size,
            f.modified_ns,
            "",
            f.selected,
        );
    }
    out
}

fn junk_section(kind: JunkKind) -> &'static str {
    match kind {
        JunkKind::SystemCache => "junk_system_cache",
        JunkKind::PartialDownload => "junk_unfinished_download",
        JunkKind::TempFile => "junk_temporary_file",
        JunkKind::EmptyFile => "junk_empty_file",
        JunkKind::BrokenLink => "junk_broken_link",
    }
}

/// Quotes a field when needed. A leading `=`, `+`, `-` or `@` would make
/// spreadsheets evaluate it as a formula, so such fields get a `'` prefix.
fn csv_field(s: &str) -> String {
    let s = if s.starts_with(['=', '+', '-', '@']) {
        format!("'{s}")
    } else {
        s.to_string()
    };
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

// ── JSON ───────────────────────────────────────────────────────────────

fn json(session: &Session, c: &Contents, clock: ReportClock) -> String {
    use serde_json::json;
    let time = |ns: i64| local_time(ns / 1_000_000, clock.utc_offset_min, true);
    let summary = session.summary();
    let value = json!({
        "tool": "DigiClean",
        "generated": local_time(clock.now_ms, clock.utc_offset_min, true),
        "roots": session.result.roots.iter().map(|r| r.to_string_lossy()).collect::<Vec<_>>(),
        "hash_algorithm": session.result.stats.hash_algorithm,
        "summary": {
            "duplicate_file_groups": summary.active_file_groups,
            "duplicate_file_bytes": summary.file_wasted,
            "duplicate_folder_groups": summary.active_folder_groups,
            "duplicate_folder_bytes": summary.folder_wasted,
            "empty_folders": summary.remaining_empty_folders,
            "large_files": summary.remaining_large_files,
            "junk_items": summary.remaining_junk,
            "junk_bytes": summary.remaining_junk_bytes,
            "selected_files": summary.files,
            "selected_file_bytes": summary.file_bytes,
            "selected_folders": summary.folders,
            "selected_folder_bytes": summary.folder_bytes,
        },
        "duplicate_files": c.files.iter().map(|g| json!({
            "size": g.size,
            "reclaimable": g.wasted,
            "hash": g.digest,
            "category": g.category,
            "copies": g.items.iter().map(|f| json!({
                "path": f.path.to_string_lossy(),
                "modified": time(f.modified_ns),
                "selected": f.selected,
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
        "duplicate_folders": c.folders.iter().map(|g| json!({
            "size": g.total_bytes,
            "files": g.file_count,
            "reclaimable": g.wasted,
            "hash": g.digest,
            "copies": g.items.iter().map(|d| json!({
                "path": d.path.to_string_lossy(),
                "modified": time(d.modified_ns),
                "selected": d.selected,
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
        "empty_folders": c.empty.iter().map(|d| json!({
            "path": d.path.to_string_lossy(),
            "selected": d.selected,
        })).collect::<Vec<_>>(),
        "junk": c.junk.iter().map(|j| json!({
            "path": j.path.to_string_lossy(),
            "kind": j.kind,
            "safe": j.kind.is_safe(),
            "size": j.size,
            "modified": time(j.modified_ns),
            "selected": j.selected,
        })).collect::<Vec<_>>(),
        "large_files": c.large.iter().map(|f| json!({
            "path": f.path.to_string_lossy(),
            "size": f.size,
            "modified": time(f.modified_ns),
            "selected": f.selected,
        })).collect::<Vec<_>>(),
    });
    serde_json::to_string_pretty(&value).unwrap_or_default()
}

// ── HTML ───────────────────────────────────────────────────────────────

const STYLE: &str = r#"
:root{--ink:#14202b;--muted:#5b6b78;--line:#dfe6ec;--soft:#f3f7f9;--brand:#112f47;--accent:#2f9e78;--remove:#b3261e}
*{box-sizing:border-box}
body{margin:0;background:#fff;color:var(--ink);font:14px/1.5 "Segoe UI",system-ui,-apple-system,Roboto,"Helvetica Neue",Arial,sans-serif}
main{max-width:1000px;margin:0 auto;padding:32px 20px 48px}
header{border-bottom:3px solid var(--brand);padding-bottom:16px;margin-bottom:24px}
h1{margin:0;font-size:26px;color:var(--brand)}
h2{margin:32px 0 8px;font-size:18px;color:var(--brand)}
.meta{color:var(--muted);margin-top:4px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.tile{background:var(--soft);border-radius:10px;padding:12px 14px}
.tile b{display:block;font-size:20px;font-variant-numeric:tabular-nums;color:var(--brand)}
.tile span{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.group{border:1px solid var(--line);border-radius:10px;margin:10px 0;break-inside:avoid;overflow:hidden}
.group h3{margin:0;padding:8px 12px;background:var(--soft);font-size:14px;display:flex;justify-content:space-between;gap:12px}
.group h3 em{font-style:normal;color:var(--accent);white-space:nowrap}
.scroll{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px 12px;border-top:1px solid var(--line);text-align:left;vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:12px}
td.path{overflow-wrap:anywhere}
td.num,th.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.tag{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.keep{background:#e3f4ec;color:#1f6b50}.remove{background:#fbe4e2;color:var(--remove)}
.note{color:var(--muted);font-size:13px}
@media print{main{padding:0}.group{break-inside:avoid}a{color:inherit}}
"#;

fn html(session: &Session, c: &Contents, clock: ReportClock) -> String {
    let s = session.summary();
    let time = |ns: i64| local_time(ns / 1_000_000, clock.utc_offset_min, false);
    let mut out = String::with_capacity(64 * 1024);
    let roots: Vec<String> = session
        .result
        .roots
        .iter()
        .map(|r| esc(&r.to_string_lossy()))
        .collect();
    let _ = write!(
        out,
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <title>DigiClean report</title><style>{STYLE}</style></head><body><main>\
         <header><h1>DigiClean report</h1>\
         <div class=\"meta\">{} · {}</div><div class=\"meta\">Scanned: {}</div></header>\
         <div class=\"tiles\">",
        local_time(clock.now_ms, clock.utc_offset_min, false),
        esc(&session.result.stats.hash_algorithm),
        roots.join(", "),
    );
    for (label, value) in [
        ("Duplicate files", human(s.file_wasted)),
        ("Duplicate groups", s.active_file_groups.to_string()),
        ("Duplicate folders", human(s.folder_wasted)),
        (
            "Selected to remove",
            human(s.file_bytes + s.folder_bytes + s.large_file_bytes),
        ),
    ] {
        let _ = write!(
            out,
            "<div class=\"tile\"><span>{label}</span><b>{value}</b></div>"
        );
    }
    out.push_str("</div><p class=\"note\">Reclaimable space keeps one copy of everything. \
        “Remove” marks copies selected for removal when the report was made; nothing has been deleted.</p>");

    // Keep/Remove only where the user made a choice in that group.
    let tag = |decided: bool, selected: bool| match (decided, selected) {
        (false, _) => "",
        (true, true) => "<span class=\"tag remove\">Remove</span>",
        (true, false) => "<span class=\"tag keep\">Keep</span>",
    };

    if !c.files.is_empty() {
        let _ = write!(out, "<h2>Duplicate files ({})</h2>", c.files.len());
        for g in c.files.iter().take(HTML_GROUP_LIMIT) {
            let name = g
                .items
                .first()
                .and_then(|f| f.path.file_name())
                .map(|n| esc(&n.to_string_lossy()))
                .unwrap_or_default();
            let _ = write!(
                out,
                "<div class=\"group\"><h3><span>{name} · {} copies · {} each</span><em>{} to free</em></h3>\
                 <div class=\"scroll\"><table>",
                g.items.len(),
                human(g.size),
                human(g.wasted),
            );
            let decided = g.items.iter().any(|f| f.selected);
            for f in &g.items {
                let _ = write!(
                    out,
                    "<tr><td>{}</td><td class=\"path\">{}</td><td class=\"num\">{}</td></tr>",
                    tag(decided, f.selected),
                    esc_path(&f.path),
                    time(f.modified_ns),
                );
            }
            out.push_str("</table></div></div>");
        }
        more(&mut out, c.files.len());
    }
    if !c.folders.is_empty() {
        let _ = write!(out, "<h2>Duplicate folders ({})</h2>", c.folders.len());
        for g in c.folders.iter().take(HTML_GROUP_LIMIT) {
            let _ = write!(
                out,
                "<div class=\"group\"><h3><span>{} copies · {} files · {} each</span><em>{} to free</em></h3>\
                 <div class=\"scroll\"><table>",
                g.items.len(),
                g.file_count,
                human(g.total_bytes),
                human(g.wasted),
            );
            let decided = g.items.iter().any(|d| d.selected);
            for d in &g.items {
                let _ = write!(
                    out,
                    "<tr><td>{}</td><td class=\"path\">{}</td><td class=\"num\">{}</td></tr>",
                    tag(decided, d.selected),
                    esc_path(&d.path),
                    time(d.modified_ns),
                );
            }
            out.push_str("</table></div></div>");
        }
        more(&mut out, c.folders.len());
    }
    if !c.large.is_empty() {
        let _ = write!(
            out,
            "<h2>Large files ({})</h2><p class=\"note\">Not duplicates: removing one removes the only copy.</p>\
             <div class=\"group\"><div class=\"scroll\"><table><tr><th>Path</th><th class=\"num\">Size</th><th class=\"num\">Modified</th></tr>",
            c.large.len()
        );
        for f in c.large.iter().take(HTML_GROUP_LIMIT) {
            let _ = write!(
                out,
                "<tr><td class=\"path\">{}{}</td><td class=\"num\">{}</td><td class=\"num\">{}</td></tr>",
                if f.selected { "<span class=\"tag remove\">Remove</span> " } else { "" },
                esc_path(&f.path),
                human(f.size),
                time(f.modified_ns),
            );
        }
        out.push_str("</table></div></div>");
        more(&mut out, c.large.len());
    }
    if !c.junk.is_empty() {
        let _ = write!(
            out,
            "<h2>Junk ({})</h2><p class=\"note\">Only system caches are always safe to remove; review the rest.</p>\
             <div class=\"group\"><div class=\"scroll\"><table><tr><th>Path</th><th>Kind</th><th class=\"num\">Size</th></tr>",
            c.junk.len()
        );
        for j in c.junk.iter().take(HTML_GROUP_LIMIT) {
            let _ = write!(
                out,
                "<tr><td class=\"path\">{}{}</td><td>{}</td><td class=\"num\">{}</td></tr>",
                if j.selected {
                    "<span class=\"tag remove\">Remove</span> "
                } else {
                    ""
                },
                esc_path(&j.path),
                j.kind.label(),
                human(j.size),
            );
        }
        out.push_str("</table></div></div>");
        more(&mut out, c.junk.len());
    }
    if !c.empty.is_empty() {
        let _ = write!(
            out,
            "<h2>Empty folders ({})</h2><div class=\"group\"><div class=\"scroll\"><table>",
            c.empty.len()
        );
        for d in c.empty.iter().take(HTML_GROUP_LIMIT) {
            let _ = write!(
                out,
                "<tr><td class=\"path\">{}{}</td></tr>",
                if d.selected {
                    "<span class=\"tag remove\">Remove</span> "
                } else {
                    ""
                },
                esc_path(&d.path),
            );
        }
        out.push_str("</table></div></div>");
        more(&mut out, c.empty.len());
    }
    if c.files.is_empty()
        && c.folders.is_empty()
        && c.large.is_empty()
        && c.empty.is_empty()
        && c.junk.is_empty()
    {
        out.push_str("<h2>Nothing to report</h2><p class=\"note\">No duplicates, large files or empty folders left.</p>");
    }
    out.push_str("</main></body></html>");
    out
}

fn more(out: &mut String, total: usize) {
    if total > HTML_GROUP_LIMIT {
        let _ = write!(
            out,
            "<p class=\"note\">… and {} more. Export CSV or JSON for the full list.</p>",
            total - HTML_GROUP_LIMIT
        );
    }
}

/// Escaped path that wraps after separators rather than inside names.
fn esc_path(path: &Path) -> String {
    esc(&path.to_string_lossy())
        .replace('\\', "\\<wbr>")
        .replace('/', "/<wbr>")
}

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Binary units, matching the app (1 KB = 1024 bytes).
pub fn human(bytes: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KB", "MB", "GB", "TB", "PB"];
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if value >= 100.0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// `2024-06-14T10:15:30+02:00` (`iso`) or `2024-06-14 10:15`.
fn local_time(epoch_ms: i64, offset_min: i32, iso: bool) -> String {
    let secs = epoch_ms.div_euclid(1000) + i64::from(offset_min) * 60;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    let (hh, mm, ss) = (rem / 3600, rem % 3600 / 60, rem % 60);
    if iso {
        let sign = if offset_min < 0 { '-' } else { '+' };
        let off = offset_min.unsigned_abs();
        format!(
            "{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}{sign}{:02}:{:02}",
            off / 60,
            off % 60
        )
    } else {
        format!("{y:04}-{m:02}-{d:02} {hh:02}:{mm:02}")
    }
}

/// Days since 1970-01-01 to a proleptic Gregorian date (H. Hinnant).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_are_written_in_local_time() {
        // 2024-02-29 23:30:00 UTC
        let ms = 1_709_249_400_000;
        assert_eq!(local_time(ms, 0, true), "2024-02-29T23:30:00+00:00");
        assert_eq!(local_time(ms, 330, true), "2024-03-01T05:00:00+05:30");
        assert_eq!(local_time(ms, -300, false), "2024-02-29 18:30");
        assert_eq!(local_time(0, 0, false), "1970-01-01 00:00");
    }

    #[test]
    fn csv_fields_are_quoted_and_never_formulas() {
        assert_eq!(csv_field("C:\\a\\b.txt"), "C:\\a\\b.txt");
        assert_eq!(csv_field("/x/a, b.txt"), "\"/x/a, b.txt\"");
        assert_eq!(csv_field("/x/say \"hi\""), "\"/x/say \"\"hi\"\"\"");
        assert_eq!(csv_field("=cmd|' /C calc'!A0"), "'=cmd|' /C calc'!A0");
    }

    #[test]
    fn html_is_escaped_and_sizes_are_binary() {
        assert_eq!(
            esc("<a href=\"x\">&'"),
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;"
        );
        assert_eq!(human(1023), "1023 B");
        assert_eq!(human(1_071_644_672), "1022 MB");
        assert_eq!(human(1536), "1.5 KB");
    }
}
