//! Power-rate model (EWMA of the draw, averages since unplug) and the "last full charge"
//! tracker.
//!
//! Two averages are kept since the unplug: the wall-clock one (energy used / elapsed time,
//! sleep included, `avg_since_unplug`) and the awake-only one (`avg_awake_w`), integrated
//! from the sampled draw over awake intervals only. An interval between two samples counts
//! as awake when the gap is at most `GAP_S` (three sampling intervals) and no sleep record
//! overlaps it; anything else is a suspend (or a stalled daemon) and is left out.

pub const TAU_S: f64 = 720.0;
/// Nominal sampling interval of the daemon.
pub const SAMPLE_S: f64 = 20.0;
/// A gap between samples longer than this is not awake time.
pub const GAP_S: f64 = 3.0 * SAMPLE_S;

#[derive(Debug, Default, Clone)]
pub struct Rates {
    pub dis_ewma: Option<f64>,
    pub chg_ewma: Option<f64>,
    /// (timestamp, energy in Wh) when the battery started discharging.
    pub unplug: Option<(f64, f64)>,
    /// Awake-only energy (Wh) and time (s) integrated since the unplug.
    awake_wh: f64,
    awake_s: f64,
    last_ts: Option<f64>,
    last_draw: Option<f64>,
    last_dis: bool,
    last_chg: bool,
}

fn blend(prev: Option<f64>, w: f64, dt: f64) -> f64 {
    match prev {
        Some(p) => {
            let a = 1.0 - (-dt / TAU_S).exp();
            p + (w - p) * a
        }
        None => w,
    }
}

impl Rates {
    /// `asleep_s` is how much of (previous sample, `ts`] the sleep log says was spent asleep.
    #[allow(clippy::too_many_arguments)]
    pub fn update(
        &mut self,
        ts: f64,
        asleep_s: f64,
        discharging: bool,
        charging: bool,
        draw_w: Option<f64>,
        chg_w: Option<f64>,
        energy_wh: Option<f64>,
    ) {
        let dt = self.last_ts.map(|l| (ts - l).max(0.0)).unwrap_or(0.0);
        // Awake interval: a short gap with no sleep in it. After a suspend the EWMA keeps
        // its pre-sleep value and moves by one nominal sample step only, so neither the
        // sleep duration nor a resume-time spike drags it.
        let awake = dt > 0.0 && dt <= GAP_S && asleep_s <= 0.0;
        let ewma_dt = if awake { dt } else { SAMPLE_S };
        if discharging {
            if !self.last_dis {
                if self.unplug.is_none() {
                    self.unplug = energy_wh.map(|e| (ts, e));
                }
                self.dis_ewma = draw_w;
                self.awake_wh = 0.0;
                self.awake_s = 0.0;
            } else {
                if let Some(w) = draw_w {
                    self.dis_ewma = Some(blend(self.dis_ewma, w, ewma_dt));
                }
                if awake {
                    if let (Some(a), Some(b)) = (self.last_draw, draw_w) {
                        self.awake_wh += 0.5 * (a + b) * dt / 3600.0;
                        self.awake_s += dt;
                    }
                }
            }
        } else {
            self.dis_ewma = None;
            self.unplug = None;
            self.awake_wh = 0.0;
            self.awake_s = 0.0;
        }
        self.last_draw = if discharging { draw_w } else { None };
        if charging {
            if !self.last_chg {
                self.chg_ewma = chg_w;
            } else if let Some(w) = chg_w {
                self.chg_ewma = Some(blend(self.chg_ewma, w, ewma_dt));
            }
        } else {
            self.chg_ewma = None;
        }
        self.last_ts = Some(ts);
        self.last_dis = discharging;
        self.last_chg = charging;
    }

    /// Seeds the unplug point (inferred from history after a daemon restart).
    pub fn seed_unplug(&mut self, ts: f64, energy_wh: f64) {
        if self.unplug.is_none() {
            self.unplug = Some((ts, energy_wh));
        }
    }

    pub fn since_unplug_s(&self, ts: f64) -> Option<f64> {
        self.unplug.map(|(t0, _)| (ts - t0).max(0.0))
    }

    /// Seconds of awake discharge integrated since the unplug.
    pub fn awake_s_since_unplug(&self) -> Option<f64> {
        self.unplug.map(|_| self.awake_s)
    }

    /// Average draw over the awake time since the unplug, or None with under a minute of it.
    pub fn avg_awake_w(&self) -> Option<f64> {
        self.unplug?;
        if self.awake_s >= 60.0 {
            Some(self.awake_wh / (self.awake_s / 3600.0))
        } else {
            None
        }
    }

    /// Average draw since the unplug, from the energy actually used (includes sleep).
    pub fn avg_since_unplug(&self, ts: f64, energy_wh: Option<f64>) -> Option<f64> {
        let (t0, e0) = self.unplug?;
        let e = energy_wh?;
        let hours = (ts - t0) / 3600.0;
        if hours * 60.0 >= 1.0 && e0 > e {
            Some((e0 - e) / hours)
        } else {
            None
        }
    }
}

/// Whether the battery counts as full: status Full, 99% or more, or at the charge limit.
pub fn is_full(status: &str, charge: Option<f64>, limit: Option<u32>) -> bool {
    if status.eq_ignore_ascii_case("full") {
        return true;
    }
    match charge {
        None => false,
        Some(c) => {
            if c >= 99.0 {
                return true;
            }
            match limit {
                Some(l) if l > 0 && l < 100 => c >= l as f64 - 0.5,
                _ => false,
            }
        }
    }
}

/// Tracks the last instant the battery was full. It is refreshed on every full sample, so
/// once the battery leaves full the stored time is when it last was.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct FullTracker {
    pub last_full_ts: Option<f64>,
    pub charge_at_full: Option<f64>,
}

impl FullTracker {
    pub fn update(&mut self, ts: f64, full: bool, charge: Option<f64>) {
        if full {
            self.last_full_ts = Some(ts);
            self.charge_at_full = Some(charge.unwrap_or(100.0));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ewma_moves_toward_new_draw() {
        let mut r = Rates::default();
        r.update(0.0, 0.0, true, false, Some(10.0), None, Some(50.0));
        assert_eq!(r.dis_ewma, Some(10.0));
        r.update(20.0, 0.0, true, false, Some(4.0), None, Some(49.9));
        let v = r.dis_ewma.unwrap();
        assert!(v < 10.0 && v > 9.0, "{}", v);
        // After a long gap (sleep) the pre-sleep EWMA stays the starting point; the first
        // sample after resume moves it by one nominal step only.
        let before = r.dis_ewma.unwrap();
        r.update(20000.0, 19000.0, true, false, Some(4.0), None, Some(40.0));
        let after = r.dis_ewma.unwrap();
        assert!(after < before && after > before - 0.2, "{} -> {}", before, after);
    }

    #[test]
    fn unplug_and_average() {
        let mut r = Rates::default();
        r.update(0.0, 0.0, true, false, Some(5.0), None, Some(50.0));
        r.update(3600.0, 0.0, true, false, Some(5.0), None, Some(45.0));
        let avg = r.avg_since_unplug(3600.0, Some(45.0)).unwrap();
        assert!((avg - 5.0).abs() < 1e-9);
        assert_eq!(r.since_unplug_s(3600.0), Some(3600.0));
        // Plugging in clears the model.
        r.update(3620.0, 0.0, false, true, None, Some(30.0), Some(45.0));
        assert!(r.unplug.is_none() && r.dis_ewma.is_none());
        assert_eq!(r.chg_ewma, Some(30.0));
    }

    /// Samples every 20 s from `from` to `to` at a constant draw.
    fn run(r: &mut Rates, from: f64, to: f64, w: f64, e: f64) -> f64 {
        let mut t = from;
        while t <= to {
            r.update(t, 0.0, true, false, Some(w), None, Some(e));
            t += SAMPLE_S;
        }
        t - SAMPLE_S
    }

    #[test]
    fn night_asleep_then_awake_average_ignores_sleep() {
        let mut r = Rates::default();
        // One awake hour at 5 W, 8 h asleep at 0.3 W, then 2 h awake at 5 W.
        let t = run(&mut r, 0.0, 3600.0, 5.0, 50.0);
        let wake = t + 8.0 * 3600.0;
        let e = 50.0 - 5.0 - 8.0 * 0.3;
        r.update(wake, 8.0 * 3600.0, true, false, Some(5.0), None, Some(e));
        let end = run(&mut r, wake + SAMPLE_S, wake + 7200.0, 5.0, e);
        let awake = r.avg_awake_w().unwrap();
        assert!((awake - 5.0).abs() < 0.05, "{}", awake);
        assert!((r.awake_s_since_unplug().unwrap() - 10800.0).abs() < 100.0);
        // The wall-clock average is dragged far down by the sleep.
        let wall = r.avg_since_unplug(end, Some(e - 10.0)).unwrap();
        assert!(wall < 2.5, "{}", wall);
    }

    #[test]
    fn gap_without_sleep_record_is_not_awake() {
        let mut r = Rates::default();
        let t = run(&mut r, 0.0, 600.0, 4.0, 50.0);
        // 1 h silent gap with no sleep record (stalled daemon): excluded.
        r.update(t + 3600.0, 0.0, true, false, Some(4.0), None, Some(46.0));
        assert!((r.awake_s_since_unplug().unwrap() - 600.0).abs() < 1.0);
        assert!((r.avg_awake_w().unwrap() - 4.0).abs() < 1e-6);
    }

    #[test]
    fn awake_average_resets_on_plug_in() {
        let mut r = Rates::default();
        run(&mut r, 0.0, 600.0, 4.0, 50.0);
        assert!(r.avg_awake_w().is_some());
        r.update(700.0, 0.0, false, true, None, Some(30.0), Some(49.0));
        assert!(r.avg_awake_w().is_none() && r.awake_s_since_unplug().is_none());
    }

    #[test]
    fn seeded_unplug_survives_first_update() {
        let mut r = Rates::default();
        r.seed_unplug(100.0, 40.0);
        r.update(200.0, 0.0, true, false, Some(5.0), None, Some(39.0));
        assert_eq!(r.unplug, Some((100.0, 40.0)));
    }

    #[test]
    fn full_detection() {
        assert!(is_full("Full", Some(97.0), None));
        assert!(is_full("Charging", Some(99.0), None));
        assert!(!is_full("Charging", Some(98.0), None));
        assert!(is_full("Not charging", Some(80.0), Some(80)));
        assert!(is_full("Not charging", Some(79.6), Some(80)));
        assert!(!is_full("Discharging", Some(70.0), Some(80)));
        assert!(!is_full("Discharging", None, None));
        // A limit of 100 or 0 means no limit.
        assert!(!is_full("Charging", Some(90.0), Some(100)));
        assert!(!is_full("Charging", Some(90.0), Some(0)));
    }

    #[test]
    fn full_tracker_keeps_last_full_instant() {
        let mut f = FullTracker::default();
        f.update(10.0, false, Some(50.0));
        assert_eq!(f.last_full_ts, None);
        f.update(100.0, true, Some(100.0));
        f.update(200.0, true, Some(99.5));
        // Unplugged and draining: the time stays where it last was full.
        f.update(300.0, false, Some(95.0));
        f.update(400.0, false, Some(90.0));
        assert_eq!(f.last_full_ts, Some(200.0));
        assert_eq!(f.charge_at_full, Some(99.5));
    }
}
