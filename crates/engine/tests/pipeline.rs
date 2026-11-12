//! End-to-end tests: real files on disk through scan, selection and actions.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use digiclean_engine::actions::{self, ActionKind, ActionRequest, ActionTarget};
use digiclean_engine::session::{
    GroupFilter, GroupKind, KeepStrategy, SelectionError, SelectionRule, SortKey,
};
use digiclean_engine::{
    run_scan, FileCategory, HashAlgorithm, ProgressSnapshot, RecoveryBin, ScanConfig, ScanControl,
    Session,
};

fn write(path: &Path, data: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, data).unwrap();
}

/// Deterministic pseudo-random content.
fn data(seed: u64, len: usize) -> Vec<u8> {
    let mut x = seed
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

fn config(root: &Path) -> ScanConfig {
    ScanConfig {
        roots: vec![root.to_path_buf()],
        threads: 2,
        ..Default::default()
    }
}

fn scan(cfg: &ScanConfig) -> Session {
    Session::new(run_scan(cfg, &ScanControl::new(), None).unwrap())
}

fn group_paths(session: &Session) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = session
        .file_groups(0, 1000, SortKey::Wasted, true, &GroupFilter::default())
        .items
        .iter()
        .map(|g| {
            let mut v: Vec<String> = g
                .items
                .iter()
                .map(|i| i.path.file_name().unwrap().to_string_lossy().into_owned())
                .collect();
            v.sort();
            v
        })
        .collect();
    out.sort();
    out
}

#[test]
fn finds_duplicates_by_content_not_name() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let big = data(1, 300_000);
    write(&root.join("a/holiday.jpg"), &big);
    write(&root.join("b/copy of holiday.jpg"), &big);
    write(&root.join("c/IMG_0001.JPG"), &big);
    // Same size, same head/tail, different middle: must not be grouped.
    let mut other = big.clone();
    other[150_000] ^= 0xff;
    write(&root.join("d/lookalike.jpg"), &other);
    write(&root.join("unique.txt"), b"only one");
    write(&root.join("small1.txt"), b"same small content");
    write(&root.join("x/small2.txt"), b"same small content");

    let session = scan(&config(root));
    let groups = group_paths(&session);
    assert_eq!(
        groups,
        vec![
            vec!["IMG_0001.JPG", "copy of holiday.jpg", "holiday.jpg"],
            vec!["small1.txt", "small2.txt"],
        ]
    );
    let stats = &session.result.stats;
    assert_eq!(stats.duplicate_groups, 2);
    assert_eq!(stats.duplicate_files, 3);
    assert_eq!(stats.wasted_bytes, 2 * 300_000 + 18);
}

#[test]
fn sha256_and_blake3_agree_on_grouping() {
    let dir = tempfile::tempdir().unwrap();
    let blob = data(9, 70_000);
    write(&dir.path().join("1.bin"), &blob);
    write(&dir.path().join("2.bin"), &blob);
    write(&dir.path().join("3.bin"), &data(10, 70_000));
    for algo in [HashAlgorithm::Blake3, HashAlgorithm::Sha256] {
        let mut cfg = config(dir.path());
        cfg.hash_algorithm = algo;
        cfg.verify_byte_by_byte = true;
        assert_eq!(group_paths(&scan(&cfg)), vec![vec!["1.bin", "2.bin"]]);
    }
}

#[test]
fn filters_limit_reported_files() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("p1.png"), &data(2, 5000));
    write(&root.join("p2.png"), &data(2, 5000));
    write(&root.join("m1.mp4"), &data(3, 50_000));
    write(&root.join("m2.mp4"), &data(3, 50_000));
    write(&root.join(".hidden1"), &data(4, 100));
    write(&root.join(".hidden2"), &data(4, 100));
    write(&root.join("skip/m3.mp4"), &data(3, 50_000));

    let mut cfg = config(root);
    cfg.categories = vec![FileCategory::Video];
    cfg.exclude_paths = vec![root.join("skip")];
    assert_eq!(group_paths(&scan(&cfg)), vec![vec!["m1.mp4", "m2.mp4"]]);

    let mut cfg = config(root);
    cfg.min_size = 10_000;
    assert_eq!(
        group_paths(&scan(&cfg)),
        vec![vec!["m1.mp4", "m2.mp4", "m3.mp4"]]
    );

    let mut cfg = config(root);
    cfg.include_hidden = true;
    cfg.max_size = Some(1000);
    assert_eq!(group_paths(&scan(&cfg)), vec![vec![".hidden1", ".hidden2"]]);

    let mut cfg = config(root);
    cfg.recursive = false;
    assert_eq!(group_paths(&scan(&cfg)).len(), 2);
}

#[test]
fn hard_links_are_not_reported_as_duplicates() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let blob = data(5, 40_000);
    write(&root.join("orig.bin"), &blob);
    fs::hard_link(root.join("orig.bin"), root.join("link.bin")).unwrap();
    let session = scan(&config(root));
    assert!(group_paths(&session).is_empty());
    assert_eq!(session.result.stats.hardlinks_skipped, 1);

    write(&root.join("real_copy.bin"), &blob);
    let session = scan(&config(root));
    let groups = group_paths(&session);
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].len(), 2);
}

#[test]
fn duplicate_folders_and_nesting() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for base in ["Photos 2023", "Backup/Photos 2023 (copy)"] {
        let b = root.join(base);
        write(&b.join("beach.jpg"), &data(11, 30_000));
        write(&b.join("tiny.txt"), b"x");
        write(&b.join("trip/day1.jpg"), &data(12, 20_000));
        write(&b.join("trip/day2.jpg"), &data(13, 20_000));
        write(&b.join("Thumbs.db"), base.as_bytes()); // junk differs and is ignored
    }
    // Same files, different structure: not a folder duplicate.
    let other = root.join("Flat");
    write(&other.join("beach.jpg"), &data(11, 30_000));
    write(&other.join("tiny.txt"), b"x");
    write(&other.join("day1.jpg"), &data(12, 20_000));
    write(&other.join("day2.jpg"), &data(13, 20_000));
    // Same structure, different content.
    let near = root.join("Near");
    write(&near.join("beach.jpg"), &data(11, 30_000));
    write(&near.join("tiny.txt"), b"y");
    write(&near.join("trip/day1.jpg"), &data(12, 20_000));
    write(&near.join("trip/day2.jpg"), &data(13, 20_000));

    let mut cfg = config(root);
    cfg.min_size = 100; // tiny.txt is filtered from file results but still compared in folders
    let session = scan(&cfg);
    let page = session.folder_groups(0, 100, SortKey::Wasted, true, &GroupFilter::default());
    // trip/ subfolders exist in 3 places (two duplicates + Near) so they form
    // their own group; it is not implied because Near is not a duplicate.
    let mut names: Vec<Vec<String>> = page
        .items
        .iter()
        .map(|g| {
            let mut v: Vec<String> = g
                .items
                .iter()
                .map(|i| {
                    i.path
                        .strip_prefix(&session.result.roots[0])
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/")
                })
                .collect();
            v.sort();
            v
        })
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            vec![
                "Backup/Photos 2023 (copy)".to_string(),
                "Photos 2023".to_string()
            ],
            vec![
                "Backup/Photos 2023 (copy)/trip".to_string(),
                "Near/trip".to_string(),
                "Photos 2023/trip".to_string()
            ],
        ]
    );
    let top = page.items.iter().find(|g| g.items.len() == 2).unwrap();
    assert_eq!(top.file_count, 4);
    assert_eq!(top.total_bytes, 30_000 + 1 + 40_000);
}

#[test]
fn nested_duplicate_folders_are_collapsed() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for base in ["A", "B"] {
        write(&root.join(base).join("x/1.bin"), &data(20, 5000));
        write(&root.join(base).join("x/y/2.bin"), &data(21, 6000));
    }
    let session = scan(&config(root));
    let page = session.folder_groups(0, 100, SortKey::Wasted, true, &GroupFilter::default());
    assert_eq!(page.total, 1, "child duplicates are implied by parents");
    assert_eq!(page.items[0].dir_count, 2);
}

#[test]
fn empty_folders_reported_top_most() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir_all(root.join("empty/nested/deeper")).unwrap();
    fs::create_dir_all(root.join("only_junk")).unwrap();
    write(&root.join("only_junk/.DS_Store"), b"junk");
    write(&root.join("full/file.txt"), b"content");
    let session = scan(&config(root));
    let mut empty: Vec<String> = session
        .empty_folders(0, 100, SortKey::Path, false, &GroupFilter::default())
        .items
        .iter()
        .map(|i| i.path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    empty.sort();
    assert_eq!(empty, vec!["empty", "only_junk"]);
}

#[test]
fn cache_makes_rescans_cheap() {
    let dir = tempfile::tempdir().unwrap();
    let cache_dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let blob = data(30, 200_000);
    write(&root.join("1.bin"), &blob);
    write(&root.join("2.bin"), &blob);
    let mut cfg = config(root);
    cfg.cache_dir = Some(cache_dir.path().to_path_buf());

    let first = scan(&cfg);
    assert_eq!(first.result.stats.files_fully_hashed, 2);
    let second = scan(&cfg);
    assert_eq!(second.result.stats.files_fully_hashed, 0);
    assert!(second.result.stats.cache_hits >= 2);
    assert_eq!(group_paths(&second), vec![vec!["1.bin", "2.bin"]]);

    // Modify one file: the cache must not hide the change.
    let mut changed = blob.clone();
    changed[100_000] ^= 1;
    fs::write(root.join("2.bin"), &changed).unwrap();
    let file = fs::File::options()
        .write(true)
        .open(root.join("2.bin"))
        .unwrap();
    file.set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(5))
        .unwrap();
    drop(file);
    let third = scan(&cfg);
    assert!(group_paths(&third).is_empty());
}

#[test]
fn progress_is_reported_and_cancel_stops() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..50 {
        write(&dir.path().join(format!("f{i}.bin")), &data(40, 50_000));
    }
    let snapshots = Arc::new(AtomicU64::new(0));
    let counter = snapshots.clone();
    let sink = Arc::new(move |_s: &ProgressSnapshot| {
        counter.fetch_add(1, Ordering::Relaxed);
    });
    let result = run_scan(&config(dir.path()), &ScanControl::new(), Some(sink)).unwrap();
    assert!(snapshots.load(Ordering::Relaxed) >= 1);
    assert_eq!(result.file_groups.len(), 1);

    let control = ScanControl::new();
    control.cancel();
    assert!(run_scan(&config(dir.path()), &control, None).is_err());
}

fn file_ids_in(session: &Session) -> Vec<Vec<u32>> {
    session
        .file_groups(0, 1000, SortKey::Wasted, true, &GroupFilter::default())
        .items
        .iter()
        .map(|g| g.items.iter().map(|i| i.id).collect())
        .collect()
}

#[test]
fn selection_never_selects_every_copy() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("a.bin"), &data(50, 9000));
    write(&dir.path().join("b.bin"), &data(50, 9000));
    let mut session = scan(&config(dir.path()));
    let ids = file_ids_in(&session).remove(0);
    session.set_file_selected(ids[0], true).unwrap();
    assert_eq!(
        session.set_file_selected(ids[1], true),
        Err(SelectionError::WouldSelectAll)
    );
    session.set_file_selected(ids[0], false).unwrap();
    session.set_file_selected(ids[1], true).unwrap();
}

#[test]
fn rules_pick_expected_keepers() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let blob = data(60, 12_000);
    write(&root.join("Downloads/photo.jpg"), &blob);
    write(&root.join("Pictures/2024/photo.jpg"), &blob);
    write(&root.join("p.jpg"), &blob);
    let mut session = scan(&config(root));
    let rule = SelectionRule {
        strategy: KeepStrategy::ShallowestPath,
        ..Default::default()
    };
    session.apply_rule(GroupKind::Files, &rule);
    let group = session
        .file_groups(0, 1, SortKey::Wasted, true, &GroupFilter::default())
        .items
        .remove(0);
    let kept: Vec<_> = group.items.iter().filter(|i| !i.selected).collect();
    assert_eq!(kept.len(), 1);
    assert!(kept[0].path.ends_with("p.jpg"));

    let rule = SelectionRule {
        strategy: KeepStrategy::ShortestPath,
        prefer_keep_in: vec![root.join("Pictures")],
        only_select_in: vec![root.join("Downloads")],
        ..Default::default()
    };
    session.apply_rule(GroupKind::Files, &rule);
    let group = session
        .file_groups(0, 1, SortKey::Wasted, true, &GroupFilter::default())
        .items
        .remove(0);
    let selected: Vec<_> = group.items.iter().filter(|i| i.selected).collect();
    assert_eq!(selected.len(), 1);
    assert!(selected[0].path.to_string_lossy().contains("Downloads"));
}

fn request(kind: ActionKind, target: ActionTarget) -> ActionRequest {
    ActionRequest {
        kind,
        target,
        destination: None,
        keep_structure: false,
        verify_content: true,
    }
}

#[test]
fn recovery_bin_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let bin_dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("keep.bin"), &data(70, 20_000));
    write(&root.join("dupe.bin"), &data(70, 20_000));
    let bin = RecoveryBin::new(vec![bin_dir.path().to_path_buf()]).unwrap();

    let mut session = scan(&config(root));
    let rule = SelectionRule {
        strategy: KeepStrategy::FirstAlphabetical,
        ..Default::default()
    };
    session.apply_rule(GroupKind::Files, &rule);
    assert_eq!(session.summary().files, 1);

    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::Files),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert_eq!(
        report.bytes_in_bin, 20_000,
        "recovery bin keeps the space until purged"
    );
    assert_eq!(report.bytes_freed, 0);
    assert!(root.join("keep.bin").exists() ^ root.join("dupe.bin").exists());
    assert_eq!(session.summary().active_file_groups, 0);

    let restored = bin.restore_batch(report.batch_id.as_deref().unwrap());
    assert_eq!(restored.restored, 1);
    assert!(root.join("keep.bin").exists() && root.join("dupe.bin").exists());

    // Undo is reflected in the session.
    let paths: Vec<PathBuf> = report.affected_paths.iter().map(PathBuf::from).collect();
    assert_eq!(session.mark_present(&paths), 1);
    assert_eq!(session.summary().active_file_groups, 1);
}

#[test]
fn modified_files_are_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("a.bin"), &data(80, 20_000));
    write(&root.join("b.bin"), &data(80, 20_000));
    let mut session = scan(&config(root));
    let ids = file_ids_in(&session).remove(0);
    session.set_file_selected(ids[1], true).unwrap();
    let target: PathBuf = session.result.file_path(ids[1]);
    fs::write(&target, b"changed after scan").unwrap();

    let report = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::Files),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 0);
    assert_eq!(report.skipped, 1);
    assert!(target.exists());
}

#[test]
fn missing_keeper_blocks_deletion() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("a.bin"), &data(81, 20_000));
    write(&root.join("b.bin"), &data(81, 20_000));
    let mut session = scan(&config(root));
    let ids = file_ids_in(&session).remove(0);
    session.set_file_selected(ids[1], true).unwrap();
    fs::remove_file(session.result.file_path(ids[0])).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::Files),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 0);
    assert!(session.result.file_path(ids[1]).exists());
}

#[test]
fn folder_then_file_actions_never_lose_the_last_copy() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for base in ["A", "B"] {
        write(&root.join(base).join("pic.jpg"), &data(90, 25_000));
        write(&root.join(base).join("doc.pdf"), &data(91, 15_000));
    }
    let mut session = scan(&config(root));

    // Select folder A for removal (keep B) …
    let folders = session.folder_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default());
    let fg = &folders.items[0];
    let a = fg.items.iter().find(|i| i.path.ends_with("A")).unwrap().id;
    session.set_dir_selected(a, true).unwrap();
    // … and the copies inside B at file level (keeping those in A).
    for g in session
        .file_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items
    {
        let in_b = g
            .items
            .iter()
            .find(|i| i.path.parent().unwrap().ends_with("B"))
            .unwrap()
            .id;
        session.set_file_selected(in_b, true).unwrap();
    }

    // File action first: B's copies go, which makes B no longer intact.
    let r1 = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::Files),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(r1.succeeded, 2);
    let r2 = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::Folders),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(r2.succeeded, 0, "A must survive because B changed");
    assert!(root.join("A/pic.jpg").exists() && root.join("A/doc.pdf").exists());
}

#[test]
fn folder_removal_and_empty_folder_cleanup() {
    let dir = tempfile::tempdir().unwrap();
    let bin_dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for base in ["X", "Y"] {
        write(&root.join(base).join("song.mp3"), &data(95, 10_000));
    }
    fs::create_dir_all(root.join("nothing/here")).unwrap();
    let bin = RecoveryBin::new(vec![bin_dir.path().to_path_buf()]).unwrap();
    let mut session = scan(&config(root));

    let rule = SelectionRule {
        strategy: KeepStrategy::FirstAlphabetical,
        ..Default::default()
    };
    session.apply_rule(GroupKind::Folders, &rule);
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::Folders),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert!(root.join("X").exists() && !root.join("Y").exists());
    // Files inside the removed folder are gone from file groups too.
    assert_eq!(session.summary().active_file_groups, 0);

    session.select_all_empty_folders(&GroupFilter::default());
    let report = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::EmptyFolders),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert!(!root.join("nothing").exists());
}

#[test]
fn move_and_hardlink_actions() {
    let dir = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("one/a.bin"), &data(100, 20_000));
    write(&root.join("two/a.bin"), &data(100, 20_000));
    write(&root.join("l1.bin"), &data(101, 20_000));
    write(&root.join("l2.bin"), &data(101, 20_000));
    let mut session = scan(&config(root));
    let groups = session
        .file_groups(0, 10, SortKey::Path, false, &GroupFilter::default())
        .items;
    for g in &groups {
        session.set_file_selected(g.items[1].id, true).unwrap();
    }
    // Move only the a.bin copy, then hard-link the l*.bin copy.
    let a_group = groups
        .iter()
        .find(|g| g.items[0].path.ends_with("a.bin"))
        .unwrap();
    let l_group = groups
        .iter()
        .find(|g| !g.items[0].path.ends_with("a.bin"))
        .unwrap();
    session
        .set_file_selected(l_group.items[1].id, false)
        .unwrap();
    let mut req = request(ActionKind::MoveTo, ActionTarget::Files);
    req.destination = Some(dest.path().to_path_buf());
    req.keep_structure = true;
    let r = actions::execute(&mut session, &req, None, &ScanControl::new(), &|_, _| {}).unwrap();
    assert_eq!(r.succeeded, 1);
    let moved_from = &a_group.items[1].path;
    assert!(!moved_from.exists());
    let root_name = session.result.roots[0].file_name().unwrap().to_owned();
    let rel = moved_from.strip_prefix(&session.result.roots[0]).unwrap();
    assert!(dest.path().join(root_name).join(rel).exists());

    session
        .set_file_selected(l_group.items[1].id, true)
        .unwrap();
    let r = actions::execute(
        &mut session,
        &request(ActionKind::ReplaceWithHardlink, ActionTarget::Files),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(r.succeeded, 1);
    let target = l_group.items[1].path.clone();
    assert_eq!(fs::read(&target).unwrap(), data(101, 20_000));
    // A rescan sees one physical file.
    let rescan = scan(&config(root));
    assert!(group_paths(&rescan).is_empty());
}

#[test]
fn large_files_are_listed_biggest_first() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("small.bin"), &data(110, 200_000));
    write(&root.join("video.mp4"), &data(111, 3 << 20));
    write(&root.join("nested/deep/archive.zip"), &data(112, 5 << 20));
    write(&root.join("photo.jpg"), &data(113, (1 << 20) + 1));
    let session = scan(&config(root));

    let page = session.large_files(0, 10, SortKey::Size, true, &GroupFilter::default());
    let names: Vec<String> = page
        .items
        .iter()
        .map(|i| i.path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        names,
        ["archive.zip", "video.mp4", "photo.jpg"],
        "files under 1 MB are not listed"
    );
    assert_eq!(session.result.stats.large_files, 3);

    let videos = GroupFilter {
        category: Some(FileCategory::Video),
        ..Default::default()
    };
    assert_eq!(
        session
            .large_files(0, 10, SortKey::Size, true, &videos)
            .total,
        1
    );
    let big = GroupFilter {
        min_size: Some(4 << 20),
        ..Default::default()
    };
    assert_eq!(
        session.large_files(0, 10, SortKey::Size, true, &big).total,
        1
    );
}

#[test]
fn large_file_removal_needs_no_duplicate_and_reports_bytes_honestly() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("unique-video.mp4"), &data(120, 2 << 20));
    write(&root.join("old-backup.zip"), &data(121, 3 << 20));
    let mut session = scan(&config(root));
    let page = session.large_files(0, 10, SortKey::Size, true, &GroupFilter::default());
    for item in &page.items {
        session.set_large_selected(item.id, true).unwrap();
    }
    // Large-file selection is separate from duplicate selection.
    assert_eq!(session.summary().large_files, 2);
    assert_eq!(session.summary().files, 0);

    // Edit one file after the scan: it must be skipped.
    let zip = root.join("old-backup.zip");
    fs::write(&zip, b"changed").unwrap();

    let report = actions::execute(
        &mut session,
        &request(ActionKind::DeletePermanently, ActionTarget::LargeFiles),
        None,
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert_eq!(report.skipped, 1);
    assert_eq!(report.bytes_freed, 2 << 20);
    assert_eq!(report.bytes_in_bin, 0);
    assert!(!root.join("unique-video.mp4").exists());
    assert!(zip.exists());
    assert_eq!(
        session
            .large_files(0, 10, SortKey::Size, true, &GroupFilter::default())
            .total,
        1
    );
}

#[test]
fn moved_files_are_not_reported_as_freed() {
    let dir = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    write(&dir.path().join("a/x.bin"), &data(130, 30_000));
    write(&dir.path().join("b/x.bin"), &data(130, 30_000));
    let mut session = scan(&config(dir.path()));
    let ids = file_ids_in(&session).remove(0);
    session.set_file_selected(ids[1], true).unwrap();
    let mut req = request(ActionKind::MoveTo, ActionTarget::Files);
    req.destination = Some(dest.path().to_path_buf());
    let report =
        actions::execute(&mut session, &req, None, &ScanControl::new(), &|_, _| {}).unwrap();
    assert_eq!(report.succeeded, 1);
    assert_eq!(report.bytes_moved, 30_000);
    assert_eq!(report.bytes_freed + report.bytes_in_bin, 0);
}

#[test]
fn ignored_content_is_hidden_and_cannot_be_selected() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("a/keep.bin"), &data(70, 9000));
    write(&root.join("b/keep.bin"), &data(70, 9000));
    write(&root.join("a/other.bin"), &data(71, 7000));
    write(&root.join("b/other.bin"), &data(71, 7000));
    let mut session = scan(&config(root));
    assert_eq!(session.summary().active_file_groups, 2);
    let first = session
        .file_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items[0]
        .clone();
    session.set_file_selected(first.items[0].id, true).unwrap();

    let digest = session.result.file_groups[first.index as usize].digest;
    let hidden = session.set_ignored_content(&[digest].into(), &Default::default());
    assert_eq!(hidden, 1);
    let summary = session.summary();
    assert_eq!(summary.active_file_groups, 1);
    assert_eq!(
        summary.files, 0,
        "members of an ignored group are deselected"
    );
    assert_eq!(group_paths(&session), vec![vec!["other.bin", "other.bin"]]);
    assert_eq!(
        session.set_file_selected(first.items[0].id, true),
        Err(SelectionError::NotPresent)
    );
    let rule = SelectionRule {
        strategy: KeepStrategy::ShallowestPath,
        prefer_keep_in: vec![],
        only_select_in: vec![],
        filter: GroupFilter::default(),
    };
    assert_eq!(session.apply_rule(GroupKind::Files, &rule), 1);
    assert_eq!(session.summary().file_bytes, 7000);

    // Clearing the list brings the group back.
    session.set_ignored_content(&Default::default(), &Default::default());
    assert_eq!(session.summary().active_file_groups, 2);
}

#[test]
fn ignored_folders_hide_their_copies_and_break_folder_matches() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for base in ["Photos", "Backup/Photos"] {
        write(&root.join(base).join("beach.jpg"), &data(80, 30_000));
        write(&root.join(base).join("trip/day1.jpg"), &data(81, 20_000));
    }
    write(&root.join("Downloads/beach.jpg"), &data(80, 30_000));
    let mut session = scan(&config(root));
    assert_eq!(session.summary().active_folder_groups, 1);
    assert_eq!(session.summary().active_file_groups, 2);

    // Ignoring Backup/Photos/trip: Backup/Photos is no longer a full copy.
    let hidden = session.ignore_folders(&[root.join("Backup/Photos/trip")]);
    assert_eq!(hidden, 1);
    assert_eq!(session.summary().active_folder_groups, 0);
    // day1.jpg has a single visible copy left; beach.jpg still has three.
    assert_eq!(
        group_paths(&session),
        vec![vec!["beach.jpg", "beach.jpg", "beach.jpg"]]
    );

    session.ignore_folders(&[root.join("Backup")]);
    assert_eq!(group_paths(&session), vec![vec!["beach.jpg", "beach.jpg"]]);
}

#[test]
fn saved_results_round_trip_with_changes_and_selection() {
    use digiclean_engine::snapshot;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    for base in ["Photos", "Backup/Photos"] {
        write(&root.join(base).join("beach.jpg"), &data(90, 30_000));
        write(&root.join(base).join("trip/day1.jpg"), &data(91, 20_000));
    }
    write(&root.join("Downloads/beach.jpg"), &data(90, 30_000));
    write(&root.join("Videos/big.mp4"), &data(92, 1 << 21));
    fs::create_dir_all(root.join("Empty/Nested")).unwrap();
    let mut session = scan(&config(&root));

    // Remove one copy, then select another, so both kinds of change are saved.
    let rule = SelectionRule {
        strategy: KeepStrategy::ShallowestPath,
        prefer_keep_in: vec![],
        only_select_in: vec![],
        filter: GroupFilter::default(),
    };
    session.apply_rule(GroupKind::Files, &rule);
    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::Files),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert!(report.succeeded > 0);
    let large = session.large_files(0, 10, SortKey::Size, true, &GroupFilter::default());
    session.set_large_selected(large.items[0].id, true).unwrap();

    let file = dir.path().join("app/last.dcsnap");
    snapshot::save(&session, 1_700_000_000_000, &file).unwrap();
    let (loaded, finished) = snapshot::load(&file).unwrap();
    assert_eq!(finished, 1_700_000_000_000);

    let (a, b) = (session.summary(), loaded.summary());
    assert_eq!(
        (
            a.active_file_groups,
            a.file_wasted,
            a.large_files,
            a.remaining_empty_folders
        ),
        (
            b.active_file_groups,
            b.file_wasted,
            b.large_files,
            b.remaining_empty_folders
        )
    );
    assert_eq!(group_paths(&session), group_paths(&loaded));
    assert_eq!(loaded.result.roots, session.result.roots);
    assert_eq!(
        loaded.result.stats.files_seen,
        session.result.stats.files_seen
    );
    for f in 0..session.result.files.len() as u32 {
        assert_eq!(loaded.file_state(f), session.file_state(f));
        assert_eq!(loaded.result.file_path(f), session.result.file_path(f));
    }

    // Damaged or truncated snapshots are refused, never half-loaded.
    let mut bytes = fs::read(&file).unwrap();
    assert!(snapshot::decode(&bytes[..bytes.len() - 1]).is_none());
    bytes[8] ^= 0xff; // version
    assert!(snapshot::decode(&bytes).is_none());
}

#[test]
fn reports_list_what_the_results_show() {
    use digiclean_engine::report::{self, ReportClock, ReportFormat};
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("a/photo, 1.jpg"), &data(100, 9000));
    write(&root.join("b/photo, 1.jpg"), &data(100, 9000));
    write(&root.join("a/notes.txt"), &data(101, 4000));
    write(&root.join("b/notes.txt"), &data(101, 4000));
    write(&root.join("big/Tom & Jerry's.mp4"), &data(102, 1 << 21));
    let mut session = scan(&config(root));
    let groups = file_ids_in(&session);
    session.set_file_selected(groups[0][1], true).unwrap();
    // Hidden groups are not reported.
    let notes = session
        .file_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items[1]
        .index;
    let digest = session.result.file_groups[notes as usize].digest;
    session.set_ignored_content(&[digest].into(), &Default::default());

    let clock = ReportClock {
        now_ms: 1_700_000_000_000,
        utc_offset_min: 60,
    };
    let csv = String::from_utf8(report::render(&session, ReportFormat::Csv, clock)).unwrap();
    let rows: Vec<&str> = csv.lines().collect();
    assert!(rows[0].starts_with("\u{feff}section,group,path"));
    let dupes: Vec<&&str> = rows
        .iter()
        .filter(|r| r.starts_with("duplicate_file,"))
        .collect();
    assert_eq!(dupes.len(), 2, "only the visible group: {csv}");
    assert!(dupes.iter().all(|r| r.contains("photo, 1.jpg\",9000,")));
    assert_eq!(dupes.iter().filter(|r| r.ends_with(",yes")).count(), 1);
    assert!(!csv.contains("notes.txt"));
    assert_eq!(
        rows.iter().filter(|r| r.starts_with("large_file,")).count(),
        1
    );

    let json: serde_json::Value =
        serde_json::from_slice(&report::render(&session, ReportFormat::Json, clock)).unwrap();
    assert_eq!(json["duplicate_files"].as_array().unwrap().len(), 1);
    assert_eq!(json["summary"]["selected_files"], 1);
    assert_eq!(json["generated"], "2023-11-14T23:13:20+01:00");

    let html = String::from_utf8(report::render(&session, ReportFormat::Html, clock)).unwrap();
    assert!(
        html.contains("Tom &amp; Jerry&#39;s.mp4"),
        "paths are escaped"
    );
    assert!(html.contains("Duplicate files (1)"));
}

#[test]
fn junk_is_found_and_removed_safely() {
    use digiclean_engine::junk::JunkKind;
    use digiclean_engine::snapshot;
    use std::time::{Duration, SystemTime};

    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    write(&root.join("Pictures/Thumbs.db"), b"cache");
    write(&root.join("Pictures/desktop.ini"), b"[.ShellClassInfo]");
    write(
        &root.join("Downloads/setup.exe.crdownload"),
        &data(110, 5000),
    );
    write(
        &root.join("Downloads/fresh.zip.crdownload"),
        &data(111, 4000),
    );
    write(&root.join("Docs/notes.txt"), b"");
    write(&root.join("Docs/.gitkeep"), b"");
    write(&root.join("Docs/~$report.docx"), &data(112, 162));
    let two_days_ago = SystemTime::now() - Duration::from_secs(2 * 86_400);
    for p in ["Downloads/setup.exe.crdownload", "Docs/~$report.docx"] {
        fs::File::options()
            .write(true)
            .open(root.join(p))
            .unwrap()
            .set_modified(two_days_ago)
            .unwrap();
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(root.join("missing"), root.join("Docs/dead link")).unwrap();

    let mut session = scan(&config(&root));
    let all = GroupFilter::default();
    let found: Vec<(String, JunkKind)> = session
        .junk(0, 100, SortKey::Name, false, &all)
        .items
        .iter()
        .map(|j| {
            (
                j.path.file_name().unwrap().to_string_lossy().into_owned(),
                j.kind,
            )
        })
        .collect();
    let mut expected = vec![
        ("Thumbs.db".to_string(), JunkKind::SystemCache),
        ("notes.txt".to_string(), JunkKind::EmptyFile),
        (
            "setup.exe.crdownload".to_string(),
            JunkKind::PartialDownload,
        ),
        ("~$report.docx".to_string(), JunkKind::TempFile),
    ];
    if cfg!(unix) {
        expected.insert(0, ("dead link".to_string(), JunkKind::BrokenLink));
    }
    let mut found_sorted = found.clone();
    found_sorted.sort();
    expected.sort();
    assert_eq!(
        found_sorted, expected,
        "fresh downloads, markers and desktop.ini are kept"
    );
    assert_eq!(session.result.stats.junk_items, expected.len() as u64);

    // "Select safe" picks only what the OS recreates.
    assert_eq!(session.select_safe_junk(&all), 1);
    let only_downloads = GroupFilter {
        junk_kind: Some(JunkKind::PartialDownload),
        ..Default::default()
    };
    let download = session
        .junk(0, 10, SortKey::Size, true, &only_downloads)
        .items[0]
        .id;
    session.set_junk_selected(download, true).unwrap();
    assert_eq!(session.summary().junk, 2);
    assert_eq!(session.summary().junk_bytes, 5 + 5000);

    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::Junk),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 2);
    assert_eq!(report.bytes_in_bin, 5005);
    assert!(!root.join("Pictures/Thumbs.db").exists());
    assert!(!root.join("Downloads/setup.exe.crdownload").exists());
    assert!(root.join("Pictures/desktop.ini").exists());
    let summary = session.summary();
    assert_eq!(summary.remaining_junk, expected.len() as u64 - 2);
    assert_eq!(summary.junk, 0);

    // Saved results keep what happened to junk.
    let (loaded, _) = snapshot::decode(&snapshot::encode(&session, 1)).unwrap();
    assert_eq!(loaded.summary().remaining_junk, summary.remaining_junk);
}

fn age(path: &Path, days: u64) {
    let when = std::time::SystemTime::now() - std::time::Duration::from_secs(days * 86_400);
    fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(when)
        .unwrap();
}

#[test]
fn storage_overview_counts_every_file_and_follows_removals() {
    use digiclean_engine::FileCategory;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    write(&root.join("Photos/a.jpg"), &data(120, 40_000));
    write(&root.join("Photos/2023/b.jpg"), &data(121, 60_000));
    write(&root.join("Docs/report.pdf"), &data(122, 10_000));
    write(&root.join("Docs/tiny.txt"), b"x"); // below min_size: still counted
    write(&root.join("readme.txt"), &data(123, 500));
    let mut cfg = config(&root);
    cfg.min_size = 100;
    cfg.categories = vec![FileCategory::Image]; // filters do not hide storage
    let mut session = scan(&cfg);

    let usage = session.category_usage();
    assert_eq!(usage[0].category, FileCategory::Image);
    assert_eq!(usage[0].bytes, 100_000);
    let total: u64 = usage.iter().map(|u| u.bytes).sum();
    assert_eq!(total, 110_501);

    let roots = session.space_children(None);
    assert_eq!(roots.len(), 1);
    assert_eq!((roots[0].bytes, roots[0].files), (110_501, 5));
    let top = session.space_children(Some(roots[0].dir));
    let names: Vec<(String, u64)> = top
        .iter()
        .map(|n| {
            let name = if n.dir == u32::MAX {
                "(files)".to_string()
            } else {
                n.path.file_name().unwrap().to_string_lossy().into_owned()
            };
            (name, n.bytes)
        })
        .collect();
    assert_eq!(
        names,
        vec![
            ("Photos".to_string(), 100_000),
            ("Docs".to_string(), 10_001),
            ("(files)".to_string(), 500)
        ]
    );
    let files_here = session.files_in(roots[0].dir, 10);
    assert_eq!(files_here.len(), 1);

    // Removing something updates the map.
    let photos = top[0].dir;
    assert_eq!(session.mark_removed(&[root.join("Photos")]), 1);
    assert_eq!(session.space_children(None)[0].bytes, 10_501);
    assert!(session
        .space_children(Some(roots[0].dir))
        .iter()
        .all(|n| n.dir != photos));
}

#[test]
fn old_files_are_filtered_by_age_place_and_type() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    let downloads = root.join("Downloads");
    write(&downloads.join("setup-2019.exe"), &data(130, 9000));
    write(&downloads.join("photo.jpg"), &data(131, 7000));
    write(&downloads.join("new.msi"), &data(132, 5000));
    write(&root.join("Docs/thesis.pdf"), &data(133, 8000));
    age(&downloads.join("setup-2019.exe"), 800);
    age(&downloads.join("photo.jpg"), 800);
    age(&root.join("Docs/thesis.pdf"), 800);
    let mut session = scan(&config(&root));

    let year_ago = digiclean_engine::walker::system_time_ns(
        std::time::SystemTime::now() - std::time::Duration::from_secs(365 * 86_400),
    );
    let names = |session: &Session, filter: &GroupFilter| -> Vec<String> {
        session
            .old_files(0, 100, SortKey::Size, true, filter)
            .items
            .iter()
            .map(|f| f.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    };
    let old = GroupFilter {
        modified_before_ns: Some(year_ago),
        ..Default::default()
    };
    assert_eq!(
        names(&session, &old),
        ["setup-2019.exe", "thesis.pdf", "photo.jpg"]
    );
    let old_downloads = GroupFilter {
        within: vec![downloads.clone()],
        ..old.clone()
    };
    assert_eq!(
        names(&session, &old_downloads),
        ["setup-2019.exe", "photo.jpg"]
    );
    let old_installers = GroupFilter {
        extensions: vec!["exe".into(), "msi".into()],
        ..old.clone()
    };
    assert_eq!(names(&session, &old_installers), ["setup-2019.exe"]);

    // Old files have their own selection, apart from the large-files list.
    let id = session
        .old_files(0, 1, SortKey::Size, true, &old_installers)
        .items[0]
        .id;
    session.set_old_selected(id, true).unwrap();
    assert_eq!(session.summary().old_files, 1);
    assert_eq!(session.summary().large_files, 0);
    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::OldFiles),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert!(!downloads.join("setup-2019.exe").exists());
    assert!(names(&session, &old_installers).is_empty());
}

#[test]
fn recommendations_only_pick_low_risk_items() {
    use digiclean_engine::session::RecommendationKind as R;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    let downloads = root.join("Downloads");
    write(&root.join("Photos/beach.jpg"), &data(140, 30_000));
    write(&downloads.join("beach.jpg"), &data(140, 30_000)); // copy of a kept photo
    write(&downloads.join("a.zip"), &data(141, 20_000));
    write(&downloads.join("a (1).zip"), &data(141, 20_000)); // both in Downloads
    write(&root.join("Photos/Thumbs.db"), b"cache");
    write(&downloads.join("big.iso.part"), &data(142, 9_000));
    age(&downloads.join("big.iso.part"), 3);
    fs::create_dir_all(root.join("Old/Empty")).unwrap();
    let mut session = scan(&config(&root));

    let recs = session.recommendations(std::slice::from_ref(&downloads));
    let by_kind = |k: R| {
        recs.iter()
            .find(|r| r.kind == k)
            .map(|r| (r.items, r.bytes))
    };
    assert_eq!(by_kind(R::SystemCaches), Some((1, 5)));
    assert_eq!(by_kind(R::LeftoverFiles), Some((1, 9_000)));
    assert_eq!(by_kind(R::DownloadDuplicates), Some((2, 50_000)));
    assert_eq!(by_kind(R::EmptyFolders), Some((1, 0)));

    assert_eq!(
        session.select_recommendation(R::DownloadDuplicates, std::slice::from_ref(&downloads)),
        GroupKind::Files
    );
    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::Files),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 2);
    assert!(
        root.join("Photos/beach.jpg").exists(),
        "the photo outside Downloads is kept"
    );
    assert!(!downloads.join("beach.jpg").exists());
    assert_eq!(
        [
            downloads.join("a.zip").exists(),
            downloads.join("a (1).zip").exists()
        ]
        .iter()
        .filter(|&&e| e)
        .count(),
        1,
        "one of two downloads is kept"
    );
    let after = session.recommendations(std::slice::from_ref(&downloads));
    assert!(after.iter().all(|r| r.kind != R::DownloadDuplicates));
}

/// A photo-like picture: gradients and two shapes, varied by `seed`.
fn scene(w: u32, h: u32, seed: u32) -> image::RgbImage {
    image::RgbImage::from_fn(w, h, |x, y| {
        let (fx, fy) = (x as f32 / w as f32, y as f32 / h as f32);
        let s = seed as f32 * 0.37;
        let blob = |cx: f32, cy: f32, r: f32| ((fx - cx).powi(2) + (fy - cy).powi(2) < r * r) as u8;
        let v = (120.0 + 90.0 * (fx * 3.0 + s).sin() * (fy * 2.0 - s).cos()) as u8;
        let shape = blob(0.3 + s.sin() * 0.1, 0.4, 0.15) * 90 + blob(0.7, 0.6, 0.1) * 70;
        image::Rgb([v.saturating_add(shape), v / 2 + shape, 255 - v])
    })
}

fn save_jpeg(img: &image::RgbImage, path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut out = fs::File::create(path).unwrap();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 88)
        .encode_image(img)
        .unwrap();
}

#[test]
fn similar_photos_keep_the_best_shot() {
    use digiclean_engine::photos::{self, PhotoIssue};
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    let original = scene(1200, 900, 1);
    save_jpeg(&original, &root.join("Camera/IMG_0001.jpg"));
    let small = image::imageops::resize(&original, 480, 360, image::imageops::FilterType::Triangle);
    save_jpeg(&small, &root.join("WhatsApp/IMG-WA0001.jpg"));
    save_jpeg(&scene(1200, 900, 9), &root.join("Camera/IMG_0002.jpg"));
    // An exact copy is a duplicate, not a "similar" set of its own.
    save_jpeg(&scene(1200, 900, 9), &root.join("Backup/IMG_0002.jpg"));
    let dark = image::RgbImage::from_fn(800, 600, |x, y| {
        let p = original.get_pixel(x, y);
        image::Rgb([p[0] / 12, p[1] / 12, p[2] / 12])
    });
    save_jpeg(&dark, &root.join("Camera/IMG_0003.jpg"));
    fs::create_dir_all(root.join("Pictures")).unwrap();
    scene(600, 1200, 4)
        .save(root.join("Pictures/Screenshot 2024-05-01.png"))
        .unwrap();
    let mut session = scan(&config(&root));

    let candidates = session.photo_candidates();
    assert_eq!(candidates.len(), 6);
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(2)
        .build()
        .unwrap();
    let cache = digiclean_engine::HashCache::open(&dir.path().join("cache")).unwrap();
    let (features, failed) = photos::analyze_many(
        &candidates,
        Some(&cache),
        &ScanControl::new(),
        &pool,
        &|| {},
    )
    .unwrap();
    assert_eq!((features.len(), failed), (6, 0));
    // A second run is served from the cache with identical results.
    let (again, _) = photos::analyze_many(
        &candidates,
        Some(&cache),
        &ScanControl::new(),
        &pool,
        &|| {},
    )
    .unwrap();
    assert_eq!(again, features);
    session.set_photo_analysis(features, failed);

    let summary = session.summary();
    assert!(summary.photos_analyzed);
    assert_eq!(summary.similar_groups, 1);
    let group = &session
        .similar_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items[0];
    let names: Vec<String> = group
        .items
        .iter()
        .map(|i| i.path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        names,
        ["IMG_0001.jpg", "IMG-WA0001.jpg"],
        "best (larger, sharper) first"
    );
    assert!(group.items[0].best);
    assert_eq!(
        session.set_similar_selected(group.items[0].id, true),
        Ok(()),
        "the best can be ticked while the other stays"
    );
    assert_eq!(
        session.set_similar_selected(group.items[1].id, true),
        Err(SelectionError::WouldSelectAll)
    );
    session.clear_selection(GroupKind::SimilarPhotos);
    assert_eq!(session.select_all_but_best(&GroupFilter::default()), 1);
    assert_eq!(session.summary().similar, 1);

    let issues = |kind: Option<PhotoIssue>| -> Vec<String> {
        session
            .photo_issue_list(
                0,
                10,
                SortKey::Name,
                false,
                &GroupFilter {
                    photo_issue: kind,
                    ..Default::default()
                },
            )
            .items
            .iter()
            .map(|i| i.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    };
    assert_eq!(issues(Some(PhotoIssue::Dark)), ["IMG_0003.jpg"]);
    assert_eq!(
        issues(Some(PhotoIssue::Screenshot)),
        ["Screenshot 2024-05-01.png"]
    );
    assert!(issues(Some(PhotoIssue::Blurry)).is_empty());

    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::SimilarPhotos),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert!(root.join("Camera/IMG_0001.jpg").exists());
    assert!(!root.join("WhatsApp/IMG-WA0001.jpg").exists());
    assert_eq!(session.summary().similar_groups, 0);
}

#[test]
fn new_downloads_that_copy_scanned_files_are_found() {
    use digiclean_engine::watch;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    write(&root.join("Photos/beach.jpg"), &data(150, 40_000));
    write(&root.join("Photos/other.jpg"), &data(151, 40_000)); // same size, other content
    let session = scan(&config(&root));
    let downloads = dir.path().join("Downloads");
    write(&downloads.join("beach (1).jpg"), &data(150, 40_000));
    write(&downloads.join("new.jpg"), &data(152, 40_000));
    write(&downloads.join("empty.txt"), b"");
    let cache = digiclean_engine::HashCache::open(&dir.path().join("cache")).unwrap();
    let found = watch::find_copies(
        &session,
        &[
            downloads.join("beach (1).jpg"),
            downloads.join("new.jpg"),
            downloads.join("empty.txt"),
            downloads.join("missing.jpg"),
            root.join("Photos/beach.jpg"), // part of the scan: not new
        ],
        Some(&cache),
    );
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].path, downloads.join("beach (1).jpg"));
    assert!(found[0].existing.ends_with("Photos/beach.jpg"));
    assert_eq!(found[0].size, 40_000);
}

#[test]
fn clones_never_lose_data_where_unsupported() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    write(&root.join("a/keep.bin"), &data(160, 30_000));
    write(&root.join("b/copy.bin"), &data(160, 30_000));
    let mut session = scan(&config(&root));
    session.apply_rule(
        GroupKind::Files,
        &SelectionRule {
            strategy: KeepStrategy::FirstAlphabetical,
            ..Default::default()
        },
    );
    let support = digiclean_engine::platform::clone_support(&root);
    let result = actions::execute(
        &mut session,
        &request(ActionKind::ReplaceWithClone, ActionTarget::Files),
        None,
        &ScanControl::new(),
        &|_, _| {},
    );
    match support {
        // NTFS and friends: refused before anything is touched.
        Some(false) => assert!(result.is_err()),
        // Supported or unknown: either cloned, or reported per file.
        _ => {
            let report = result.unwrap();
            assert_eq!(report.succeeded + report.failed + report.skipped, 1);
        }
    }
    for p in ["a/keep.bin", "b/copy.bin"] {
        assert_eq!(
            fs::read(root.join(p)).unwrap(),
            data(160, 30_000),
            "{p} intact"
        );
    }
    assert!(!root.join("b/.copy.bin.digiclean-clone").exists());
}

#[test]
fn similar_songs_keep_the_best_copy() {
    use digiclean_engine::media;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    for sub in ["Music", "Phone", "Backup"] {
        fs::create_dir_all(root.join(sub)).unwrap();
    }
    media::write_wav(
        &root.join("Music/Song.wav"),
        44_100,
        &media::synth_song(5, 44_100, 25.0, 1.0),
    )
    .unwrap();
    media::write_wav(
        &root.join("Phone/Song (low).wav"),
        22_050,
        &media::synth_song(5, 22_050, 25.0, 0.7),
    )
    .unwrap();
    // A byte-identical copy of the other song: a duplicate, not a "similar" set.
    let other = media::synth_song(6, 44_100, 25.0, 1.0);
    media::write_wav(&root.join("Music/Other.wav"), 44_100, &other).unwrap();
    media::write_wav(&root.join("Backup/Other.wav"), 44_100, &other).unwrap();
    let mut session = scan(&config(&root));

    let candidates = session.media_candidates();
    assert_eq!(candidates.len(), 4);
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(2)
        .build()
        .unwrap();
    let (features, failed) =
        media::analyze_many(&candidates, None, &ScanControl::new(), &pool, &|| {}).unwrap();
    assert_eq!((features.len(), failed), (4, 0));
    session.set_media_analysis(features, failed);

    let summary = session.summary();
    assert!(summary.media_analyzed);
    assert_eq!(
        summary.media_groups, 1,
        "the identical pair is a duplicate group"
    );
    let group = &session
        .media_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items[0];
    assert_eq!(group.items.len(), 2);
    assert!(group.items[0].best && group.items[0].path.ends_with("Music/Song.wav"));
    assert_eq!(group.items[0].duration_ms, Some(25_000));
    assert_eq!(session.set_media_selected(group.items[0].id, true), Ok(()));
    assert_eq!(
        session.set_media_selected(group.items[1].id, true),
        Err(SelectionError::WouldSelectAll)
    );
    session.clear_selection(GroupKind::SimilarMedia);
    assert_eq!(
        session.select_all_but_best_media(&GroupFilter::default()),
        1
    );

    let bin = RecoveryBin::new(vec![dir.path().join("bin")]).unwrap();
    let report = actions::execute(
        &mut session,
        &request(ActionKind::RecoveryBin, ActionTarget::SimilarMedia),
        Some(&bin),
        &ScanControl::new(),
        &|_, _| {},
    )
    .unwrap();
    assert_eq!(report.succeeded, 1);
    assert!(root.join("Music/Song.wav").exists());
    assert!(!root.join("Phone/Song (low).wav").exists());
    assert_eq!(session.summary().media_groups, 0);
}

#[test]
fn background_check_saves_results_and_decides_on_a_notice() {
    use digiclean_engine::background::{run_check, CheckJob};
    use digiclean_engine::snapshot;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data");
    write(&root.join("a/big.bin"), &data(170, 300_000));
    write(&root.join("b/big.bin"), &data(170, 300_000));
    write(&root.join("a/kept.bin"), &data(171, 200_000));
    write(&root.join("b/kept.bin"), &data(171, 200_000));
    let mut job = CheckJob {
        config: config(&root),
        snapshot: Some(dir.path().join("app/last-results.dcsnap")),
        result: dir.path().join("app/check.json"),
        ignored_files: vec![],
        ignored_folders: vec![],
        notify_min_bytes: 400_000,
        low_space_percent: 0,
    };
    // The job file round-trips through JSON (the app writes it).
    let json = serde_json::to_string(&job).unwrap();
    let parsed: CheckJob = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.result, job.result);

    let result = run_check(&job, &ScanControl::new()).unwrap();
    assert_eq!(result.duplicate_groups, 2);
    assert_eq!(result.duplicate_bytes, 500_000);
    assert!(result.low_space.is_empty());
    assert!(
        result.notice.as_ref().unwrap().body.contains("488 KB"),
        "{result:?}"
    );
    let saved: digiclean_engine::background::CheckResult =
        serde_json::from_slice(&fs::read(&job.result).unwrap()).unwrap();
    assert_eq!(saved, result);
    let (session, _) = snapshot::load(job.snapshot.as_ref().unwrap()).unwrap();
    assert_eq!(session.summary().active_file_groups, 2);

    // Ignored groups do not count; below the threshold there is no notice.
    let big = session
        .file_groups(0, 10, SortKey::Wasted, true, &GroupFilter::default())
        .items[0]
        .digest
        .clone();
    job.ignored_files = vec![big];
    let quieter = run_check(&job, &ScanControl::new()).unwrap();
    assert_eq!(quieter.duplicate_groups, 1);
    assert_eq!(quieter.duplicate_bytes, 200_000);
    assert_eq!(quieter.notice, None);

    // A drive below the threshold is reported (every drive is below 100%).
    job.low_space_percent = 100;
    let full = run_check(&job, &ScanControl::new()).unwrap();
    assert_eq!(full.low_space.len(), 1);
    assert_eq!(full.notice.unwrap().title, "Your drive is almost full");
}
