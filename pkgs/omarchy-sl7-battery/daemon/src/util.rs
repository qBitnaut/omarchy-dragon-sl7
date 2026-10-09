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
