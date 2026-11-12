//! `digiclean-check --job <file>`: the background check the system scheduler
//! runs while DigiClean is closed (see `digiclean_engine::background`).
//! A windowless program on Windows, so scheduled runs never flash a console.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::path::PathBuf;
use std::process::ExitCode;

use digiclean_engine::background::{notify, run_check, CheckJob};
use digiclean_engine::ScanControl;

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let job = match (args.next(), args.next()) {
        (Some(flag), Some(path)) if flag == "--job" => PathBuf::from(path),
        _ => {
            eprintln!("usage: digiclean-check --job <file>");
            return ExitCode::from(2);
        }
    };
    let run = || -> Result<(), String> {
        let text = std::fs::read_to_string(&job).map_err(|e| format!("{}: {e}", job.display()))?;
        let job: CheckJob = serde_json::from_str(&text).map_err(|e| format!("invalid job: {e}"))?;
        let result = run_check(&job, &ScanControl::new()).map_err(|e| e.to_string())?;
        if let Some(notice) = &result.notice {
            notify(notice)?;
        }
        Ok(())
    };
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("digiclean-check: {e}");
            ExitCode::FAILURE
        }
    }
}
