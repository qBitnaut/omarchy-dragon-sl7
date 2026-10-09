//! Fixed-size ring files of time buckets: 1-minute buckets for 7 days and 15-minute
//! buckets for 1 year. A slot is `bucket_index % capacity`; a record is valid only when
//! its stored bucket index matches, so stale slots read as gaps. The whole ring lives in
//! memory; only dirty slots are written back by `flush`.

use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

pub const REC_SIZE: usize = 24;
pub const HEADER: usize = 16;
const MAGIC: &[u8; 4] = b"SL7B";
const VERSION: u16 = 1;
pub const NONE_U16: u16 = 0xFFFF;
pub const NONE_I16: i16 = i16::MIN;

pub const M1_RES: u32 = 60;
pub const M1_CAP: usize = 7 * 24 * 60;
pub const M15_RES: u32 = 900;
pub const M15_CAP: usize = 365 * 24 * 4;

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rec {
    /// Bucket index (unix seconds / resolution). 0 marks an empty slot.
    pub t: u32,
    pub n: u16,
    /// Average charge, percent x 100.
    pub charge: u16,
    /// Average temperature, tenths of a degree.
    pub temp: i16,
    /// Average voltage, millivolts.
    pub volt: u16,
    /// Average draw while discharging, watts x 100.
    pub dis_w: u16,
    /// Average charging power, watts x 100.
    pub chg_w: u16,
    pub dis_n: u16,
    pub chg_n: u16,
    /// Percent of samples with the screen on.
    pub screen: u8,
    /// Percent of samples on AC.
    pub ac: u8,
}

impl Rec {
    pub fn encode(&self) -> [u8; REC_SIZE] {
        let mut b = [0u8; REC_SIZE];
        b[0..4].copy_from_slice(&self.t.to_le_bytes());
        b[4..6].copy_from_slice(&self.n.to_le_bytes());
        b[6..8].copy_from_slice(&self.charge.to_le_bytes());
        b[8..10].copy_from_slice(&self.temp.to_le_bytes());
        b[10..12].copy_from_slice(&self.volt.to_le_bytes());
        b[12..14].copy_from_slice(&self.dis_w.to_le_bytes());
        b[14..16].copy_from_slice(&self.chg_w.to_le_bytes());
        b[16..18].copy_from_slice(&self.dis_n.to_le_bytes());
        b[18..20].copy_from_slice(&self.chg_n.to_le_bytes());
        b[20] = self.screen;
        b[21] = self.ac;
        b
    }

    pub fn decode(b: &[u8]) -> Rec {
        let u16at = |i: usize| u16::from_le_bytes([b[i], b[i + 1]]);
        Rec {
            t: u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            n: u16at(4),
            charge: u16at(6),
            temp: i16::from_le_bytes([b[8], b[9]]),
            volt: u16at(10),
            dis_w: u16at(12),
            chg_w: u16at(14),
            dis_n: u16at(16),
            chg_n: u16at(18),
            screen: b[20],
            ac: b[21],
        }
    }
}

/// One sample's values as they enter the buckets.
#[derive(Clone, Copy, Debug, Default)]
pub struct SampleVals {
    pub charge: Option<f64>,
    pub temp_c: Option<f64>,
    pub volt_v: Option<f64>,
    pub dis_w: Option<f64>,
    pub chg_w: Option<f64>,
    pub screen_on: bool,
    pub ac: bool,
}

/// Running sums for the bucket currently being filled.
#[derive(Clone, Debug)]
pub struct Acc {
    pub idx: u32,
    n: u32,
    charge: f64,
    temp: f64,
    temp_n: u32,
    volt: f64,
    volt_n: u32,
    dis: f64,
    dis_n: u32,
    chg: f64,
    chg_n: u32,
    screen: u32,
    ac: u32,
}

impl Acc {
    pub fn new(idx: u32) -> Acc {
        Acc { idx, n: 0, charge: 0.0, temp: 0.0, temp_n: 0, volt: 0.0, volt_n: 0, dis: 0.0, dis_n: 0, chg: 0.0, chg_n: 0, screen: 0, ac: 0 }
    }

    /// Continues a partially filled bucket that was flushed earlier.
    pub fn from_rec(r: &Rec) -> Acc {
        let n = r.n as u32;
        let nf = n as f64;
        let mut a = Acc::new(r.t);
        a.n = n;
        a.charge = r.charge as f64 / 100.0 * nf;
        if r.temp != NONE_I16 {
            a.temp_n = n;
            a.temp = r.temp as f64 / 10.0 * nf;
        }
        if r.volt != NONE_U16 {
            a.volt_n = n;
            a.volt = r.volt as f64 / 1000.0 * nf;
        }
        if r.dis_w != NONE_U16 {
            a.dis_n = r.dis_n as u32;
            a.dis = r.dis_w as f64 / 100.0 * r.dis_n as f64;
        }
        if r.chg_w != NONE_U16 {
            a.chg_n = r.chg_n as u32;
            a.chg = r.chg_w as f64 / 100.0 * r.chg_n as f64;
        }
        a.screen = (r.screen as f64 / 100.0 * nf).round() as u32;
        a.ac = (r.ac as f64 / 100.0 * nf).round() as u32;
        a
    }

    /// Samples without a charge reading are not recorded.
    pub fn add(&mut self, s: &SampleVals) {
        let c = match s.charge {
            Some(c) => c,
            None => return,
        };
        self.n += 1;
        self.charge += c.clamp(0.0, 100.0);
        if let Some(t) = s.temp_c {
            self.temp += t;
            self.temp_n += 1;
        }
        if let Some(v) = s.volt_v {
            self.volt += v;
            self.volt_n += 1;
        }
        if let Some(w) = s.dis_w {
            self.dis += w;
            self.dis_n += 1;
        }
        if let Some(w) = s.chg_w {
            self.chg += w;
            self.chg_n += 1;
        }
        if s.screen_on {
            self.screen += 1;
        }
        if s.ac {
            self.ac += 1;
        }
    }

    pub fn to_rec(&self) -> Rec {
        let nf = self.n.max(1) as f64;
        let pct = |count: u32| -> u8 { (count as f64 * 100.0 / nf).round().clamp(0.0, 100.0) as u8 };
        Rec {
            t: self.idx,
            n: self.n.min(u16::MAX as u32) as u16,
            charge: (self.charge / nf * 100.0).round().clamp(0.0, 10000.0) as u16,
            temp: if self.temp_n > 0 {
                (self.temp / self.temp_n as f64 * 10.0).round().clamp(-3000.0, 3000.0) as i16
            } else {
                NONE_I16
            },
            volt: if self.volt_n > 0 {
                (self.volt / self.volt_n as f64 * 1000.0).round().clamp(0.0, 60000.0) as u16
            } else {
                NONE_U16
            },
            dis_w: if self.dis_n > 0 {
                (self.dis / self.dis_n as f64 * 100.0).round().clamp(0.0, 60000.0) as u16
            } else {
                NONE_U16
            },
            chg_w: if self.chg_n > 0 {
                (self.chg / self.chg_n as f64 * 100.0).round().clamp(0.0, 60000.0) as u16
            } else {
                NONE_U16
            },
            dis_n: self.dis_n.min(u16::MAX as u32) as u16,
            chg_n: self.chg_n.min(u16::MAX as u32) as u16,
            screen: pct(self.screen),
            ac: pct(self.ac),
        }
    }
}

/// Weighted averages over a span of buckets (one chart column).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Col {
    pub charge: Option<f64>,
    pub dis_w: Option<f64>,
    pub chg_w: Option<f64>,
    pub temp: Option<f64>,
    pub volt: Option<f64>,
    pub screen: Option<f64>,
    pub ac: Option<f64>,
}

pub struct Ring {
    path: Option<PathBuf>,
    pub res: u32,
    cap: usize,
    recs: Vec<Rec>,
    dirty: Vec<usize>,
    needs_header: bool,
}

impl Ring {
    pub fn new_mem(res: u32, cap: usize) -> Ring {
        Ring { path: None, res, cap, recs: vec![Rec::default(); cap], dirty: Vec::new(), needs_header: false }
    }

    /// Opens (or prepares) a ring file. A missing, short or mismatched file starts empty
    /// and is created by the first flush.
    pub fn open(path: &Path, res: u32, cap: usize) -> Ring {
        let mut ring = Ring::new_mem(res, cap);
        ring.path = Some(path.to_path_buf());
        ring.needs_header = true;
        let mut data = Vec::new();
        let read_ok = File::open(path).and_then(|mut f| f.read_to_end(&mut data)).is_ok();
        if read_ok && data.len() == HEADER + cap * REC_SIZE && &data[0..4] == MAGIC {
            let ver = u16::from_le_bytes([data[4], data[5]]);
            let rsize = u16::from_le_bytes([data[6], data[7]]) as usize;
            let r = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
            let c = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;
            if ver == VERSION && rsize == REC_SIZE && r == res && c == cap {
                for i in 0..cap {
                    let off = HEADER + i * REC_SIZE;
                    ring.recs[i] = Rec::decode(&data[off..off + REC_SIZE]);
                }
                ring.needs_header = false;
            }
        }
        ring
    }

    fn slot(&self, idx: u32) -> usize {
        idx as usize % self.cap
    }

    pub fn get(&self, idx: u32) -> Option<Rec> {
        let r = self.recs[self.slot(idx)];
        if r.t == idx && r.n > 0 {
            Some(r)
        } else {
            None
        }
    }

    pub fn put(&mut self, rec: Rec) {
        let s = self.slot(rec.t);
        self.recs[s] = rec;
        if self.dirty.last() != Some(&s) {
            self.dirty.push(s);
        }
    }

    pub fn flush(&mut self) -> io::Result<()> {
        let path = match &self.path {
            Some(p) => p.clone(),
            None => return Ok(()),
        };
        if self.dirty.is_empty() && !self.needs_header {
            return Ok(());
        }
        let file = OpenOptions::new().write(true).create(true).truncate(false).open(&path)?;
        if self.needs_header {
            // Truncate first so nothing of a mismatched old file survives as records.
            file.set_len(0)?;
            file.set_len((HEADER + self.cap * REC_SIZE) as u64)?;
            let mut h = [0u8; HEADER];
            h[0..4].copy_from_slice(MAGIC);
            h[4..6].copy_from_slice(&VERSION.to_le_bytes());
            h[6..8].copy_from_slice(&(REC_SIZE as u16).to_le_bytes());
            h[8..12].copy_from_slice(&self.res.to_le_bytes());
            h[12..16].copy_from_slice(&(self.cap as u32).to_le_bytes());
            file.write_all_at(&h, 0)?;
            // A fresh file holds only what is in memory (usually nothing or the current bucket).
            self.dirty = (0..self.cap).filter(|i| self.recs[*i].t != 0).collect();
            self.needs_header = false;
        }
        self.dirty.sort_unstable();
        self.dirty.dedup();
        for s in self.dirty.drain(..) {
            file.write_all_at(&self.recs[s].encode(), (HEADER + s * REC_SIZE) as u64)?;
        }
        Ok(())
    }

    /// Weighted averages of the buckets whose start lies in [t0, t1).
    pub fn aggregate(&self, t0: f64, t1: f64) -> Col {
        let res = self.res as f64;
        let lo = (t0 / res).ceil().max(1.0) as i64;
        let hi = (t1 / res).ceil() as i64;
        let (mut n, mut charge) = (0.0, 0.0);
        let (mut temp, mut temp_n) = (0.0, 0.0);
        let (mut volt, mut volt_n) = (0.0, 0.0);
        let (mut dis, mut dis_n) = (0.0, 0.0);
        let (mut chg, mut chg_n) = (0.0, 0.0);
        let (mut screen, mut ac) = (0.0, 0.0);
        let mut i = lo;
        while i < hi && i - lo < 200_000 {
            if let Some(r) = self.get(i as u32) {
                let w = r.n as f64;
                n += w;
                charge += r.charge as f64 / 100.0 * w;
                if r.temp != NONE_I16 {
                    temp += r.temp as f64 / 10.0 * w;
                    temp_n += w;
                }
                if r.volt != NONE_U16 {
                    volt += r.volt as f64 / 1000.0 * w;
                    volt_n += w;
                }
                if r.dis_w != NONE_U16 && r.dis_n > 0 {
                    dis += r.dis_w as f64 / 100.0 * r.dis_n as f64;
                    dis_n += r.dis_n as f64;
                }
                if r.chg_w != NONE_U16 && r.chg_n > 0 {
                    chg += r.chg_w as f64 / 100.0 * r.chg_n as f64;
                    chg_n += r.chg_n as f64;
                }
                screen += r.screen as f64 / 100.0 * w;
                ac += r.ac as f64 / 100.0 * w;
            }
            i += 1;
        }
        let avg = |sum: f64, count: f64| if count > 0.0 { Some(sum / count) } else { None };
        Col {
            charge: avg(charge, n),
            dis_w: avg(dis, dis_n),
            chg_w: avg(chg, chg_n),
            temp: avg(temp, temp_n),
            volt: avg(volt, volt_n),
            screen: avg(screen, n),
            ac: avg(ac, n),
        }
    }

    /// The most recent bucket at or before `now` whose average charge is at least `pct`.
    /// Returns (bucket start, charge). Scans back at most one full ring.
    pub fn last_at_or_above(&self, pct: f64, now: f64) -> Option<(f64, f64)> {
        let top = (now / self.res as f64).floor() as i64;
        let mut i = top;
        while i > 0 && top - i < self.cap as i64 {
            if let Some(r) = self.get(i as u32) {
                let c = r.charge as f64 / 100.0;
                if c >= pct {
                    return Some((i as f64 * self.res as f64, c));
                }
            }
            i -= 1;
        }
        None
    }

    /// The latest record present, if any.
    pub fn latest(&self) -> Option<Rec> {
        self.recs.iter().filter(|r| r.t != 0 && r.n > 0).max_by_key(|r| r.t).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vals(charge: f64, dis: Option<f64>, screen: bool, ac: bool) -> SampleVals {
        SampleVals { charge: Some(charge), temp_c: Some(30.0), volt_v: Some(15.0), dis_w: dis, chg_w: None, screen_on: screen, ac }
    }

    #[test]
    fn rec_roundtrip() {
        let r = Rec { t: 12345, n: 3, charge: 5550, temp: 312, volt: 15200, dis_w: 450, chg_w: NONE_U16, dis_n: 3, chg_n: 0, screen: 66, ac: 0 };
        assert_eq!(Rec::decode(&r.encode()), r);
    }

    #[test]
    fn acc_averages_and_continues() {
        let mut a = Acc::new(10);
        a.add(&vals(80.0, Some(5.0), true, false));
        a.add(&vals(78.0, Some(7.0), false, false));
        let r = a.to_rec();
        assert_eq!(r.n, 2);
        assert_eq!(r.charge, 7900);
        assert_eq!(r.dis_w, 600);
        assert_eq!(r.screen, 50);
        assert_eq!(r.ac, 0);
        let mut b = Acc::from_rec(&r);
        b.add(&vals(76.0, Some(6.0), true, false));
        let r2 = b.to_rec();
        assert_eq!(r2.n, 3);
        assert_eq!(r2.charge, 7800);
        assert_eq!(r2.dis_w, 600);
    }

    #[test]
    fn acc_skips_samples_without_charge() {
        let mut a = Acc::new(1);
        a.add(&SampleVals::default());
        assert_eq!(a.to_rec().n, 0);
    }

    #[test]
    fn stale_slot_is_a_gap() {
        let mut ring = Ring::new_mem(60, 100);
        let mut a = Acc::new(5);
        a.add(&vals(50.0, None, true, true));
        ring.put(a.to_rec());
        assert!(ring.get(5).is_some());
        // Same slot, different bucket index.
        assert!(ring.get(105).is_none());
    }

    #[test]
    fn aggregate_weights_by_samples() {
        let mut ring = Ring::new_mem(60, 1000);
        let mut a = Acc::new(10);
        a.add(&vals(90.0, Some(4.0), true, false));
        ring.put(a.to_rec());
        let mut b = Acc::new(11);
        b.add(&vals(80.0, Some(8.0), false, false));
        b.add(&vals(80.0, Some(8.0), false, false));
        b.add(&vals(80.0, Some(8.0), false, false));
        ring.put(b.to_rec());
        let col = ring.aggregate(600.0, 720.0);
        assert!((col.charge.unwrap() - 82.5).abs() < 1e-6);
        assert!((col.dis_w.unwrap() - 7.0).abs() < 1e-6);
        assert!((col.screen.unwrap() - 0.25).abs() < 1e-6);
        assert_eq!(ring.aggregate(0.0, 60.0).charge, None);
    }

    #[test]
    fn last_at_or_above_finds_most_recent() {
        let mut ring = Ring::new_mem(60, 1000);
        for (idx, c) in [(100u32, 100.0), (110, 60.0), (120, 99.5), (130, 40.0)] {
            let mut a = Acc::new(idx);
            a.add(&vals(c, None, true, false));
            ring.put(a.to_rec());
        }
        let (ts, c) = ring.last_at_or_above(99.0, 140.0 * 60.0).unwrap();
        assert_eq!(ts, 120.0 * 60.0);
        assert!((c - 99.5).abs() < 1e-6);
        assert!(ring.last_at_or_above(100.5, 140.0 * 60.0).is_none());
    }

    #[test]
    fn file_roundtrip() {
        let dir = std::env::temp_dir().join(format!("sl7b-ring-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("m1.ring");
        let _ = std::fs::remove_file(&path);
        let mut ring = Ring::open(&path, 60, 50);
        let mut a = Acc::new(7);
        a.add(&vals(64.0, Some(3.5), true, false));
        ring.put(a.to_rec());
        ring.flush().unwrap();
        let again = Ring::open(&path, 60, 50);
        let r = again.get(7).unwrap();
        assert_eq!(r.charge, 6400);
        assert_eq!(r.dis_w, 350);
        // A different capacity discards the file.
        let other = Ring::open(&path, 60, 60);
        assert!(other.get(7).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
