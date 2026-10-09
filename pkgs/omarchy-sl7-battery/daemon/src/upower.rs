//! One-time import of UPower's charge history to seed the long-range chart.

use std::path::Path;

use crate::ring::{Acc, Ring, SampleVals, M15_RES};

/// Lines of `time<TAB>percent<TAB>state`. Returns (time, percent, charging).
pub fn parse_history(text: &str) -> Vec<(f64, f64, bool)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let mut it = line.split_whitespace();
        let (t, v, s) = match (it.next(), it.next(), it.next()) {
            (Some(t), Some(v), Some(s)) => (t, v, s),
            _ => continue,
        };
        let (t, v) = match (t.parse::<f64>(), v.parse::<f64>()) {
            (Ok(t), Ok(v)) => (t, v),
            _ => continue,
        };
        if !(0.0..=100.0).contains(&v) || t <= 0.0 {
            continue;
        }
        let charging = matches!(s, "charging" | "fully-charged" | "pending-charge");
        out.push((t, v, charging));
    }
    out
}

fn put_bucket(acc: Option<Acc>, ring: &mut Ring, added: &mut usize) {
    if let Some(a) = acc {
        if ring.get(a.idx).is_none() {
            ring.put(a.to_rec());
            *added += 1;
        }
    }
}

/// Fills empty 15-minute buckets from the history-charge files in `dir`. Files that are
/// not readable (root-only) are skipped. Returns the number of buckets added.
pub fn import(dir: &Path, ring: &mut Ring, now: f64) -> usize {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return 0,
    };
    let oldest = now - 365.0 * 86400.0;
    let mut points: Vec<(f64, f64, bool)> = Vec::new();
    for e in entries.filter_map(|e| e.ok()) {
        let name = e.file_name().to_string_lossy().to_string();
        if !(name.starts_with("history-charge-") && name.ends_with(".dat")) {
            continue;
        }
        if let Ok(text) = std::fs::read_to_string(e.path()) {
            points.extend(parse_history(&text).into_iter().filter(|p| p.0 >= oldest && p.0 <= now));
        }
    }
    points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut added = 0;
    let mut cur: Option<Acc> = None;
    for (t, v, charging) in points {
        let idx = (t / M15_RES as f64) as u32;
        if cur.as_ref().map(|a| a.idx) != Some(idx) {
            put_bucket(cur.take(), ring, &mut added);
            cur = Some(Acc::new(idx));
        }
        if let Some(a) = cur.as_mut() {
            a.add(&SampleVals { charge: Some(v), temp_c: None, volt_v: None, dis_w: None, chg_w: None, screen_on: false, ac: charging });
        }
    }
    put_bucket(cur.take(), ring, &mut added);
    added
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_skips_junk() {
        let text = "1700000000\t80.000\tdischarging\n1700000100\t79.5\tcharging\nbad line\n1700000200\t140\tcharging\n";
        let p = parse_history(text);
        assert_eq!(p.len(), 2);
        assert_eq!(p[0], (1700000000.0, 80.0, false));
        assert!(p[1].2);
    }

    #[test]
    fn imports_into_empty_buckets_only() {
        let dir = std::env::temp_dir().join(format!("sl7b-up-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let base = 1_700_000_000.0;
        std::fs::write(
            dir.join("history-charge-x.dat"),
            format!("{}\t90\tdischarging\n{}\t88\tdischarging\n{}\t70\tdischarging\n", base, base + 60.0, base + 3600.0),
        )
        .unwrap();
        std::fs::write(dir.join("history-rate-x.dat"), "1\t2\tx\n").unwrap();
        let mut ring = Ring::new_mem(M15_RES, 40000);
        let n = import(&dir, &mut ring, base + 7200.0);
        assert_eq!(n, 2);
        let r = ring.get((base / 900.0) as u32).unwrap();
        assert_eq!(r.charge, 8900);
        assert_eq!(import(&dir, &mut ring, base + 7200.0), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
