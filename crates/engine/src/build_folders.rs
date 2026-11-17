//! Build folders: what a project's own tools create and recreate on the
//! next build — `node_modules`, Rust and Maven `target`, Gradle and Flutter
//! `build`, Python virtual environments and so on. On a developer's computer
//! they are often the biggest folders of all, and removing one loses nothing
//! a build cannot bring back.
//!
//! A folder only counts when its project says so: `node_modules` next to a
//! `package.json`, `target` next to a `Cargo.toml` or a `pom.xml`. A folder
//! that holds a project of its own (or a `.git`) never counts, whatever its
//! name. Folders are reported top-most (never the `node_modules` inside
//! another one) and never as a scan root.
//!
//! Build folders the scan does not enter are still found: hidden ones
//! (`.gradle`, `.dart_tool`, `.venv`…) when hidden folders are not scanned,
//! and those matching an exclusion pattern (the app skips `**/node_modules`
//! by default, to keep package files out of the duplicates). The walk
//! records their names and they are measured here, without their files
//! joining the scan. Folders excluded by path, protected folders and system
//! folders are never looked at.
//!
//! Every folder is measured on its own: files, bytes and the newest file.
//! Removal measures again first, so a folder that changed since the scan
//! (a build ran) is skipped.

use std::ffi::OsStr;
use std::fs;
use std::io::Read;
use std::path::Path;

use rayon::prelude::*;

use crate::control::ScanControl;
use crate::error::Result;
use crate::model::{BuildDir, DirRecord, FileRecord, NO_ID};
use crate::walker::system_time_ns;

/// How one kind of build folder is recognised.
#[derive(Debug, PartialEq, Eq)]
pub struct Rule {
    /// Stable key, saved with results.
    pub id: &'static str,
    /// Folder names this rule applies to. Empty: any name, recognised by a
    /// file inside instead (`inside`), and only in scanned folders.
    pub names: &'static [&'static str],
    /// The project folder (the parent) contains one of these. `*.ext`
    /// matches any file with that extension; `a/b` a nested file.
    pub project: &'static [&'static str],
    /// The folder itself contains one of these.
    pub inside: &'static [&'static str],
    /// The parent folder has this name (`Xcode/DerivedData`).
    pub parent_named: Option<&'static str>,
    /// Who makes it, for people: "Node.js".
    pub tool: &'static str,
    /// How to get it back: "npm install".
    pub rebuild: &'static str,
}

const fn rule(
    id: &'static str,
    names: &'static [&'static str],
    project: &'static [&'static str],
    tool: &'static str,
    rebuild: &'static str,
) -> Rule {
    Rule {
        id,
        names,
        project,
        inside: &[],
        parent_named: None,
        tool,
        rebuild,
    }
}

const GRADLE: &[&str] = &["build.gradle", "build.gradle.kts"];
const PYTHON: &[&str] = &[
    "requirements.txt",
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "Pipfile",
    "poetry.lock",
    "uv.lock",
];

/// Every kind of build folder, most specific first: the first rule that
/// matches decides what a folder is.
pub static RULES: &[Rule] = &[
    rule(
        "node_modules",
        &["node_modules"],
        &["package.json"],
        "Node.js",
        "npm install",
    ),
    rule(
        "bower_components",
        &["bower_components"],
        &["bower.json"],
        "Bower",
        "bower install",
    ),
    rule(
        "next",
        &[".next"],
        &["package.json"],
        "Next.js",
        "next build",
    ),
    rule(
        "nuxt",
        &[".nuxt", ".output"],
        &["nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs"],
        "Nuxt",
        "nuxt build",
    ),
    rule(
        "svelte_kit",
        &[".svelte-kit"],
        &["package.json"],
        "SvelteKit",
        "vite build",
    ),
    rule(
        "angular",
        &[".angular"],
        &["angular.json"],
        "Angular",
        "ng build",
    ),
    rule(
        "parcel",
        &[".parcel-cache"],
        &["package.json"],
        "Parcel",
        "parcel build",
    ),
    rule(
        "turbo",
        &[".turbo"],
        &["turbo.json", "package.json"],
        "Turborepo",
        "turbo run build",
    ),
    rule(
        "rust_target",
        &["target"],
        &["Cargo.toml"],
        "Rust",
        "cargo build",
    ),
    rule(
        "maven_target",
        &["target"],
        &["pom.xml"],
        "Maven",
        "mvn package",
    ),
    rule(
        "flutter_build",
        &["build"],
        &["pubspec.yaml"],
        "Flutter",
        "flutter build",
    ),
    rule(
        "dart_tool",
        &[".dart_tool"],
        &["pubspec.yaml"],
        "Dart",
        "dart pub get",
    ),
    rule("gradle_build", &["build"], GRADLE, "Gradle", "gradle build"),
    rule(
        "gradle_cache",
        &[".gradle"],
        &[
            "build.gradle",
            "build.gradle.kts",
            "settings.gradle",
            "settings.gradle.kts",
            "gradlew",
        ],
        "Gradle",
        "gradle build",
    ),
    rule(
        "android_cxx",
        &[".cxx"],
        GRADLE,
        "Android NDK",
        "gradle build",
    ),
    Rule {
        inside: &["Debug", "Release"],
        ..rule(
            "dotnet",
            &["bin", "obj"],
            &["*.csproj", "*.fsproj", "*.vbproj"],
            ".NET",
            "dotnet build",
        )
    },
    Rule {
        inside: &["pyvenv.cfg"],
        ..rule(
            "python_venv",
            &[".venv", "venv", "env"],
            PYTHON,
            "Python",
            "python -m venv, then install the requirements",
        )
    },
    Rule {
        inside: &["CACHEDIR.TAG"],
        ..rule(
            "python_cache",
            &[".pytest_cache", ".mypy_cache", ".ruff_cache"],
            &[],
            "Python",
            "recreated on the next run",
        )
    },
    rule(
        "tox",
        &[".tox"],
        &["tox.ini", "pyproject.toml", "setup.cfg"],
        "Python tox",
        "tox",
    ),
    rule("nox", &[".nox"], &["noxfile.py"], "Python nox", "nox"),
    rule(
        "cocoapods",
        &["Pods"],
        &["Podfile"],
        "CocoaPods",
        "pod install",
    ),
    Rule {
        parent_named: Some("Xcode"),
        ..rule(
            "xcode_derived_data",
            &["DerivedData"],
            &[],
            "Xcode",
            "build again in Xcode",
        )
    },
    rule(
        "elixir",
        &["_build", "deps"],
        &["mix.exs"],
        "Elixir",
        "mix deps.get, then mix compile",
    ),
    rule(
        "haskell_stack",
        &[".stack-work"],
        &["stack.yaml"],
        "Haskell Stack",
        "stack build",
    ),
    rule(
        "zig",
        &["zig-cache", ".zig-cache", "zig-out"],
        &["build.zig"],
        "Zig",
        "zig build",
    ),
    rule("elm", &["elm-stuff"], &["elm.json"], "Elm", "elm make"),
    rule(
        "composer",
        &["vendor"],
        &["composer.lock"],
        "PHP Composer",
        "composer install",
    ),
    rule(
        "terraform",
        &[".terraform"],
        &["*.tf"],
        "Terraform",
        "terraform init",
    ),
    rule(
        "unity",
        &["Library"],
        &["ProjectSettings/ProjectVersion.txt"],
        "Unity",
        "open the project in Unity",
    ),
    rule(
        "unreal",
        &["Intermediate", "DerivedDataCache"],
        &["*.uproject"],
        "Unreal Engine",
        "open the project in Unreal Editor",
    ),
    // Any name: recognised by a file inside.
    Rule {
        inside: &["CMakeCache.txt"],
        ..rule("cmake", &[], &[], "CMake", "configure and build with CMake")
    },
    Rule {
        inside: &[CACHEDIR_TAG],
        ..rule(
            "cachedir_tag",
            &[],
            &[],
            "Cache",
            "recreated by the program that made it",
        )
    },
];

const CACHEDIR_TAG: &str = "CACHEDIR.TAG";
/// First line of a valid `CACHEDIR.TAG` (Cache Directory Tagging Specification).
const CACHEDIR_SIGNATURE: &[u8] = b"Signature: 8a477f597d28d172789f06886806bc55";

/// A folder holding one of these is a project or a repository, never a
/// build folder, whatever its name.
const PROJECT_FILES: &[&str] = &[
    ".git",
    "package.json",
    "Cargo.toml",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "pubspec.yaml",
    "pyproject.toml",
    "setup.py",
    "go.mod",
    "CMakeLists.txt",
    "Podfile",
    "mix.exs",
    "stack.yaml",
    "build.zig",
    "composer.json",
];

/// The rule with this id (for saved results).
pub fn rule_by_id(id: &str) -> Option<&'static Rule> {
    RULES.iter().find(|r| r.id == id)
}

/// A name some build folder may have: the walk records folders with these
/// names even when it does not enter them.
pub fn is_candidate_name(name: &OsStr) -> bool {
    name.to_str()
        .is_some_and(|n| RULES.iter().any(|r| r.names.contains(&n)))
}

impl Rule {
    /// Whether `dir` (named after this rule, inside `parent`) is this kind
    /// of build folder, checked on disk.
    fn matches(&self, dir: &Path, parent: &Path) -> bool {
        if let Some(name) = self.parent_named {
            if parent.file_name() != Some(OsStr::new(name)) {
                return false;
            }
        }
        if !self.project.is_empty() && !self.project.iter().any(|m| has_entry(parent, m)) {
            return false;
        }
        if !self.inside.is_empty() && !self.inside.iter().any(|m| has_entry(dir, m)) {
            return false;
        }
        if self.inside.contains(&CACHEDIR_TAG) && !valid_cachedir_tag(&dir.join(CACHEDIR_TAG)) {
            return false;
        }
        !looks_like_project(dir)
    }
}

/// `dir` contains `entry`: a name, a nested path, or `*.ext` for any file
/// with that extension.
fn has_entry(dir: &Path, entry: &str) -> bool {
    match entry.strip_prefix("*.") {
        Some(ext) => fs::read_dir(dir).is_ok_and(|entries| {
            entries.flatten().any(|e| {
                Path::new(&e.file_name())
                    .extension()
                    .is_some_and(|x| x.eq_ignore_ascii_case(ext))
                    && e.file_type().is_ok_and(|t| t.is_file())
            })
        }),
        None => fs::symlink_metadata(dir.join(entry)).is_ok(),
    }
}

fn looks_like_project(dir: &Path) -> bool {
    PROJECT_FILES.iter().any(|f| has_entry(dir, f))
}

fn valid_cachedir_tag(path: &Path) -> bool {
    let mut head = [0u8; CACHEDIR_SIGNATURE.len()];
    fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut head))
        .is_ok()
        && head == CACHEDIR_SIGNATURE
}

/// The rule a folder matches, checked on disk. A real folder only: links
/// are never build folders (removing one could reach outside the project).
pub fn classify(dir: &Path) -> Option<&'static Rule> {
    if !fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir()) {
        return None;
    }
    let name = dir.file_name()?.to_str()?;
    let parent = dir.parent()?;
    RULES.iter().find(|r| {
        (r.names.contains(&name) || (r.names.is_empty() && has_entry(dir, r.inside[0])))
            && r.matches(dir, parent)
    })
}

/// Size of a build folder at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Measure {
    pub files: u64,
    pub bytes: u64,
    /// Newest modification of a file inside (ns since the epoch), 0 if none.
    pub newest_ns: i64,
}

/// Files, bytes and newest file below `dir`, without following links.
/// `Ok(None)` when part of it cannot be read; `Err` only when cancelled.
pub fn measure(dir: &Path, control: &ScanControl) -> Result<Option<Measure>> {
    let mut m = Measure::default();
    let mut stack = vec![dir.to_path_buf()];
    let mut seen = 0u32;
    while let Some(d) = stack.pop() {
        let Ok(entries) = fs::read_dir(&d) else {
            return Ok(None);
        };
        for entry in entries {
            seen = seen.wrapping_add(1);
            if seen % 4096 == 0 {
                control.checkpoint()?;
            }
            let Ok(entry) = entry else {
                return Ok(None);
            };
            let Ok(kind) = entry.file_type() else {
                return Ok(None);
            };
            if kind.is_dir() {
                stack.push(entry.path());
            } else if kind.is_file() {
                let Ok(meta) = entry.metadata() else {
                    return Ok(None);
                };
                m.files += 1;
                m.bytes += meta.len();
                let modified = meta.modified().map(system_time_ns).unwrap_or(0);
                m.newest_ns = m.newest_ns.max(modified);
            }
            // Links and special files are left as they are: removing the
            // folder removes the link, never its target.
        }
    }
    Ok(Some(m))
}

/// A folder found by the walk, before it is measured.
struct Found {
    parent: u32,
    dir: u32,
    name: Box<OsStr>,
    rule: &'static Rule,
}

/// Finds the build folders of a walk and measures them. `skipped` lists the
/// folders the walk did not enter whose names a build folder may have, as
/// (parent, name).
pub fn detect(
    dirs: &[DirRecord],
    files: &[FileRecord],
    skipped: &[(u32, Box<OsStr>)],
    control: &ScanControl,
    pool: &rayon::ThreadPool,
) -> Result<Vec<BuildDir>> {
    let n = dirs.len();
    // `true` for a build folder, or any folder inside one.
    let mut claimed = vec![false; n];
    let mut is_build = vec![false; n];
    let mut found: Vec<Found> = Vec::new();
    let has_file = |d: usize, name: &str| {
        dirs[d]
            .files
            .iter()
            .any(|&f| files[f as usize].name.as_ref() == OsStr::new(name))
    };

    // Parents come before their children (child id > parent id).
    for d in 0..n {
        let record = &dirs[d];
        if record.parent != NO_ID && claimed[record.parent as usize] {
            claimed[d] = true;
            continue;
        }
        if record.is_root || record.parent == NO_ID {
            continue;
        }
        let name = record.name();
        let candidate = is_candidate_name(name)
            || RULES
                .iter()
                .any(|r| r.names.is_empty() && has_file(d, r.inside[0]));
        if !candidate {
            continue;
        }
        if let Some(rule) = classify(&record.path) {
            claimed[d] = true;
            is_build[d] = true;
            found.push(Found {
                parent: record.parent,
                dir: d as u32,
                name: name.into(),
                rule,
            });
        }
    }
    for (parent, name) in skipped {
        if claimed[*parent as usize] {
            continue;
        }
        if let Some(rule) = classify(&dirs[*parent as usize].path.join(&**name)) {
            found.push(Found {
                parent: *parent,
                dir: NO_ID,
                name: name.clone(),
                rule,
            });
        }
    }
    if found.is_empty() {
        return Ok(Vec::new());
    }

    // Newest file of every folder's tree, leaving build folders out: when
    // the project itself last changed.
    let mut newest = vec![0i64; n];
    for d in (0..n).rev() {
        let mut m = dirs[d]
            .files
            .iter()
            .map(|&f| files[f as usize].modified_ns)
            .max()
            .unwrap_or(0);
        for &s in &dirs[d].subdirs {
            if !is_build[s as usize] {
                m = m.max(newest[s as usize]);
            }
        }
        newest[d] = m;
    }

    let measured: Vec<Option<Measure>> = pool.install(|| {
        found
            .par_iter()
            .map(|f| measure(&dirs[f.parent as usize].path.join(&*f.name), control))
            .collect::<Result<Vec<_>>>()
    })?;
    let mut out: Vec<BuildDir> = found
        .into_iter()
        .zip(measured)
        .filter_map(|(f, m)| {
            let m = m?;
            // Nothing to free.
            (m.bytes > 0).then(|| BuildDir {
                project_modified_ns: newest[f.parent as usize],
                parent: f.parent,
                dir: f.dir,
                name: f.name,
                rule: f.rule,
                files: m.files,
                bytes: m.bytes,
                newest_ns: m.newest_ns,
            })
        })
        .collect();
    out.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.parent.cmp(&b.parent)));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, data: &[u8]) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, data).unwrap();
    }

    #[test]
    fn every_rule_needs_evidence_beyond_a_name() {
        for r in RULES {
            assert!(
                !r.project.is_empty() || !r.inside.is_empty() || r.parent_named.is_some(),
                "{} would match on its name alone",
                r.id
            );
            if r.names.is_empty() {
                assert!(!r.inside.is_empty(), "{} matches nothing", r.id);
            }
            assert_eq!(rule_by_id(r.id), Some(r), "ids are unique");
        }
    }

    #[test]
    fn folders_count_only_next_to_their_project() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        write(&p.join("web/package.json"), b"{}");
        write(&p.join("web/node_modules/a/index.js"), b"x");
        write(&p.join("loose/node_modules/a/index.js"), b"x");
        write(&p.join("crate/Cargo.toml"), b"[package]");
        write(&p.join("crate/target/debug/app"), b"x");
        write(&p.join("maven/pom.xml"), b"<project/>");
        write(&p.join("maven/target/app.jar"), b"x");
        write(&p.join("docs/target/notes.txt"), b"x");

        assert_eq!(
            classify(&p.join("web/node_modules")).unwrap().tool,
            "Node.js"
        );
        assert_eq!(classify(&p.join("loose/node_modules")), None);
        assert_eq!(classify(&p.join("crate/target")).unwrap().tool, "Rust");
        assert_eq!(classify(&p.join("maven/target")).unwrap().tool, "Maven");
        assert_eq!(classify(&p.join("docs/target")), None);
    }

    #[test]
    fn a_folder_with_its_own_project_is_never_a_build_folder() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        write(&p.join("ws/Cargo.toml"), b"[workspace]");
        // A workspace member that happens to be called "target".
        write(&p.join("ws/target/Cargo.toml"), b"[package]");
        write(&p.join("ws/target/src/lib.rs"), b"");
        assert_eq!(classify(&p.join("ws/target")), None);

        write(&p.join("app/pubspec.yaml"), b"name: app");
        write(&p.join("app/build/.git/HEAD"), b"ref");
        assert_eq!(classify(&p.join("app/build")), None);
    }

    #[test]
    fn rules_with_extra_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        write(&p.join("py/requirements.txt"), b"requests");
        write(&p.join("py/.venv/pyvenv.cfg"), b"home = x");
        write(&p.join("py2/requirements.txt"), b"requests");
        write(&p.join("py2/env/settings.txt"), b"not a venv");
        write(&p.join("net/App.csproj"), b"<Project/>");
        write(&p.join("net/bin/Debug/app.dll"), b"x");
        write(&p.join("net2/App.csproj"), b"<Project/>");
        write(&p.join("net2/bin/tool.sh"), b"x");
        write(&p.join("cm/CMakeLists.txt"), b"project(x)");
        write(&p.join("cm/out/CMakeCache.txt"), b"x");
        write(&p.join("cm/out/app.o"), b"x");
        // An in-source CMake build: the source folder itself is the project.
        write(&p.join("src2/CMakeLists.txt"), b"project(x)");
        write(&p.join("src2/CMakeCache.txt"), b"x");
        write(&p.join("tagged/CACHEDIR.TAG"), CACHEDIR_SIGNATURE);
        write(
            &p.join("fake/CACHEDIR.TAG"),
            b"not the signature at all, no",
        );

        assert_eq!(classify(&p.join("py/.venv")).unwrap().id, "python_venv");
        assert_eq!(classify(&p.join("py2/env")), None);
        assert_eq!(classify(&p.join("net/bin")).unwrap().id, "dotnet");
        assert_eq!(classify(&p.join("net2/bin")), None);
        assert_eq!(classify(&p.join("cm/out")).unwrap().id, "cmake");
        assert_eq!(classify(&p.join("src2")), None);
        assert_eq!(classify(&p.join("tagged")).unwrap().id, "cachedir_tag");
        assert_eq!(classify(&p.join("fake")), None);
    }

    #[test]
    fn measure_counts_files_and_finds_the_newest() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("node_modules");
        write(&p.join("a/one.js"), &[0; 10]);
        write(&p.join("b/c/two.js"), &[0; 25]);
        let m = measure(&p, &ScanControl::new()).unwrap().unwrap();
        assert_eq!((m.files, m.bytes), (2, 35));
        assert!(m.newest_ns > 0);
        assert_eq!(
            measure(&dir.path().join("missing"), &ScanControl::new()).unwrap(),
            None
        );
    }
}
