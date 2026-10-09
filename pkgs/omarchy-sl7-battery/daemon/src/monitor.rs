//! D-Bus signal watchers. Each runs `gdbus monitor` in its own thread and turns lines into
//! events; a monitor that exits is restarted with a backoff.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

use crate::app::Event;

/// `PrepareForSleep (true,)` -> Some(true)
pub fn parse_sleep(line: &str) -> Option<bool> {
    if !line.contains("PrepareForSleep") {
        return None;
    }
    if line.contains("(true,)") {
        Some(true)
    } else if line.contains("(false,)") {
        Some(false)
    } else {
        None
    }
}

/// `{'ActiveProfile': <'power-saver'>}` -> power-saver
pub fn parse_active_profile(line: &str) -> Option<String> {
    let key = "'ActiveProfile': <'";
    let a = line.find(key)? + key.len();
    let rest = &line[a..];
    let b = rest.find('\'')?;
    Some(rest[..b].to_string())
}

fn map_sleep(line: &str) -> Option<Event> {
    parse_sleep(line).map(Event::Sleep)
}

fn map_ppd(line: &str) -> Option<Event> {
    if line.contains("ActiveProfile") {
        Some(Event::Profile(parse_active_profile(line)))
    } else {
        None
    }
}

fn map_power(line: &str) -> Option<Event> {
    if line.contains("OnBattery") {
        Some(Event::Power)
    } else {
        None
    }
}

fn spawn_lines(args: &'static [&'static str], map: fn(&str) -> Option<Event>, tx: Sender<Event>) {
    std::thread::spawn(move || {
        let mut backoff = 2u64;
        loop {
            let started = Instant::now();
            let child = Command::new("gdbus")
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn();
            if let Ok(mut c) = child {
                if let Some(out) = c.stdout.take() {
                    for line in BufReader::new(out).lines() {
                        let l = match line {
                            Ok(l) => l,
                            Err(_) => break,
                        };
                        if let Some(ev) = map(&l) {
                            if tx.send(ev).is_err() {
                                let _ = c.kill();
                                let _ = c.wait();
                                return;
                            }
                        }
                    }
                }
                let _ = c.kill();
                let _ = c.wait();
            }
            if started.elapsed() > Duration::from_secs(60) {
                backoff = 2;
            }
            std::thread::sleep(Duration::from_secs(backoff));
            backoff = (backoff * 2).min(60);
        }
    });
}

pub fn start_all(tx: &Sender<Event>) {
    spawn_lines(
        &["monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"],
        map_sleep,
        tx.clone(),
    );
    spawn_lines(&["monitor", "--system", "--dest", "org.freedesktop.UPower.PowerProfiles"], map_ppd, tx.clone());
    spawn_lines(
        &["monitor", "--system", "--dest", "org.freedesktop.UPower", "--object-path", "/org/freedesktop/UPower"],
        map_power,
        tx.clone(),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_lines() {
        let l = "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)";
        assert_eq!(parse_sleep(l), Some(true));
        assert_eq!(parse_sleep(&l.replace("true", "false")), Some(false));
        assert_eq!(parse_sleep("/x: org.freedesktop.login1.Manager.SessionNew ('1', '/x')"), None);
    }

    #[test]
    fn profile_lines() {
        let l = "/org/freedesktop/UPower/PowerProfiles: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.UPower.PowerProfiles', {'ActiveProfile': <'power-saver'>}, @as [])";
        assert_eq!(parse_active_profile(l), Some("power-saver".to_string()));
        assert_eq!(parse_active_profile("{'Other': <1>}"), None);
        assert!(matches!(map_ppd(l), Some(Event::Profile(Some(_)))));
        assert!(map_ppd("{'PerformanceDegraded': <''>}").is_none());
    }

    #[test]
    fn power_lines() {
        assert!(map_power("... {'OnBattery': <true>} ...").is_some());
        assert!(map_power("... {'LidIsClosed': <true>} ...").is_none());
    }
}
