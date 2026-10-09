//! Small helpers: wall clock, file reads and a command runner with a timeout.

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Moves an unreadable data file aside as `<name>.bad-<unix time>` so it is never truncated
/// or overwritten, and says so on stderr (the journal). Returns the new path.
pub fn move_aside(path: &Path, why: &str) -> Option<std::path::PathBuf> {
    let name = path.file_name()?.to_string_lossy().to_string();
    let mut stamp = now_secs() as u64;
    loop {
        let dest = path.with_file_name(format!("{}.bad-{}", name, stamp));
        if !dest.exists() {
            return match std::fs::rename(path, &dest) {
                Ok(()) => {
                    eprintln!("sl7-batteryd: {} ({}); kept as {}", path.display(), why, dest.display());
                    Some(dest)
                }
                Err(e) => {
                    eprintln!("sl7-batteryd: cannot move {} aside: {}", path.display(), e);
                    None
                }
            };
        }
        stamp += 1;
    }
}

/// Writes `bytes` to `<path>.tmp`, syncs it and renames it over `path`, so a crash leaves
/// either the old file or the new one, never half of one.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = path.with_file_name(format!("{}.tmp", name));
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, path)
}

pub fn read_trim(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub fn read_f64(path: &Path) -> Option<f64> {
    read_trim(path).and_then(|s| s.parse::<f64>().ok())
}

pub fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

pub fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Runs `cmd` and returns its stdout when it exits successfully within `timeout`.
pub fn run(cmd: &str, args: &[&str], timeout: Duration) -> Option<String> {
    run_env(cmd, args, &[], timeout)
}

pub fn run_env(cmd: &str, args: &[&str], envs: &[(&str, &str)], timeout: Duration) -> Option<String> {
    let mut command = Command::new(cmd);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (k, v) in envs {
        command.env(k, v);
    }
    let mut child = command.spawn().ok()?;
    let mut out = child.stdout.take()?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut s = String::new();
                let _ = out.read_to_string(&mut s);
                return if status.success() { Some(s) } else { None };
            }
            Ok(None) => {
                if start.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            Err(_) => return None,
        }
    }
}

/// Like `run` but succeeds on exit status only.
pub fn run_ok(cmd: &str, args: &[&str], timeout: Duration) -> bool {
    run(cmd, args, timeout).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding() {
        assert_eq!(round1(1.26), 1.3);
        assert_eq!(round2(1.234), 1.23);
    }

    #[test]
    fn run_true_and_false() {
        assert!(run_ok("true", &[], Duration::from_secs(2)));
        assert!(!run_ok("false", &[], Duration::from_secs(2)));
        assert!(run("sh", &["-c", "echo hi"], Duration::from_secs(2)).unwrap().starts_with("hi"));
    }
}
