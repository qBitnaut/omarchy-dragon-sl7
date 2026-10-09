//! Sleep periods (logind PrepareForSleep) kept in a small JSON-lines log.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::util;

const KEEP: usize = 500;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Sleep {
    pub start: f64,
    pub end: f64,
    pub charge_before: Option<f64>,
    pub charge_after: Option<f64>,
    pub energy_before_wh: Option<f64>,
    pub energy_after_wh: Option<f64>,
    pub ac: bool,
    pub wake_irqs: Option<u32>,
}

impl Sleep {
    pub fn duration(&self) -> f64 {
        (self.end - self.start).max(0.0)
    }

    pub fn drain_pct(&self) -> Option<f64> {
        Some(self.charge_before? - self.charge_after?)
    }

    pub fn avg_w(&self) -> Option<f64> {
        let hours = self.duration() / 3600.0;
        if hours <= 0.0 {
            return None;
        }
        Some((self.energy_before_wh? - self.energy_after_wh?) / hours)
    }
}

pub struct SleepLog {
    path: Option<PathBuf>,
    pub items: Vec<Sleep>,
}

impl SleepLog {
    pub fn in_memory() -> SleepLog {
        SleepLog { path: None, items: Vec::new() }
    }

    pub fn load(path: &Path) -> SleepLog {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let mut items: Vec<Sleep> = Vec::new();
        let mut bad = 0usize;
        for l in text.lines().filter(|l| !l.trim().is_empty()) {
            match serde_json::from_str(l) {
                Ok(s) => items.push(s),
                Err(_) => bad += 1,
            }
        }
        let total = items.len();
        if bad > 0 || total > KEEP + 100 {
            // Rewriting drops the lines we cannot parse: keep the original first.
            if bad > 0 {
                let _ = std::fs::copy(path, path.with_file_name(format!("sleeps.jsonl.bad-{}", util::now_secs() as u64)));
                eprintln!("sl7-batteryd: {} unreadable line(s) in {}; original kept as .bad-<ts>", bad, path.display());
            }
            if total > KEEP + 100 {
                items.drain(0..total - KEEP);
            }
            let body: String = items
                .iter()
                .filter_map(|s| serde_json::to_string(s).ok())
                .map(|l| l + "\n")
                .collect();
            let _ = util::write_atomic(path, body.as_bytes());
        }
        SleepLog { path: Some(path.to_path_buf()), items }
    }

    pub fn append(&mut self, s: Sleep) {
        if let Some(p) = &self.path {
            if let Ok(line) = serde_json::to_string(&s) {
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
                    let _ = writeln!(f, "{}", line);
                }
            }
        }
        self.items.push(s);
    }

    /// Seconds of [t0, t1) spent asleep.
    pub fn overlap(&self, t0: f64, t1: f64) -> f64 {
        self.items
            .iter()
            .map(|s| (s.end.min(t1) - s.start.max(t0)).max(0.0))
            .sum()
    }
}

/// Wake interrupts the omarchy-surface-sl7 system-sleep hook logged in the window.
pub fn count_wake_irqs(start: f64, end: f64) -> Option<u32> {
    let since = format!("@{}", start.floor() as i64);
    let until = format!("@{}", end.ceil() as i64 + 5);
    let out = util::run(
        "journalctl",
        &["-t", "omarchy-surface-sl7", "--since", &since, "--until", &until, "--no-pager", "-o", "cat"],
        Duration::from_secs(8),
    )?;
    Some(out.lines().filter(|l| l.contains("wake: irq")).count() as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sleep(start: f64, end: f64) -> Sleep {
        Sleep {
            start,
            end,
            charge_before: Some(80.0),
            charge_after: Some(74.0),
            energy_before_wh: Some(40.0),
            energy_after_wh: Some(37.0),
            ac: false,
            wake_irqs: Some(3),
        }
    }

    #[test]
    fn derived_values() {
        let s = sleep(0.0, 3.0 * 3600.0);
        assert_eq!(s.drain_pct(), Some(6.0));
        assert!((s.avg_w().unwrap() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn overlap_clips_to_window() {
        let mut log = SleepLog::in_memory();
        log.append(sleep(100.0, 200.0));
        log.append(sleep(300.0, 400.0));
        assert_eq!(log.overlap(0.0, 1000.0), 200.0);
        assert_eq!(log.overlap(150.0, 350.0), 100.0);
        assert_eq!(log.overlap(500.0, 600.0), 0.0);
    }

    #[test]
    fn file_roundtrip() {
        let dir = std::env::temp_dir().join(format!("sl7b-sleep-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sleeps.jsonl");
        let _ = std::fs::remove_file(&path);
        let mut log = SleepLog::load(&path);
        log.append(sleep(1.0, 2.0));
        log.append(sleep(3.0, 4.0));
        let again = SleepLog::load(&path);
        assert_eq!(again.items.len(), 2);
        assert_eq!(again.items[1].start, 3.0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
