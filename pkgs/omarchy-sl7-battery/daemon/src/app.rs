//! Daemon state: sampling, history, the rate model, the auto power saver and the socket
//! protocol (newline-delimited JSON: hello, request/response, push).

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::auto::{Auto, AutoAct, AutoIn, SAVER};
use crate::config::Config;
use crate::rates::{is_full, FullTracker, Rates};
use crate::ring::{Acc, Ring, SampleVals, M15_CAP, M15_RES, M1_CAP, M1_RES};
use crate::sleeps::{count_wake_irqs, Sleep, SleepLog};
use crate::sys::{self, Battery};
use crate::upower;
use crate::util::{now_secs, round1, round2};

pub enum Event {
    Connected(u64, UnixStream),
    Line(u64, String),
    Disconnected(u64),
    Sleep(bool),
    /// A PPD ActiveProfile change; None means "read it again".
    Profile(Option<String>),
    Power,
    Shutdown,
}

#[derive(Clone, Debug)]
pub struct Paths {
    pub ps: PathBuf,
    pub state_dir: PathBuf,
    pub config: PathBuf,
    pub upower_dir: PathBuf,
    pub hwmon: PathBuf,
    pub cpufreq: PathBuf,
    pub run_dir: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let dir_env = |var: &str, fallback: &str| -> PathBuf {
            match std::env::var(var) {
                Ok(v) if !v.is_empty() => PathBuf::from(v),
                _ => Path::new(&home).join(fallback),
            }
        };
        Paths {
            ps: PathBuf::from(std::env::var("SL7_BATTERYD_PS").unwrap_or_else(|_| sys::PS_DIR.to_string())),
            state_dir: dir_env("XDG_STATE_HOME", ".local/state").join("sl7-battery"),
            config: dir_env("XDG_CONFIG_HOME", ".config").join("omarchy-sl7-battery").join("config.json"),
            upower_dir: PathBuf::from("/var/lib/upower"),
            hwmon: PathBuf::from("/sys/class/hwmon"),
            cpufreq: PathBuf::from("/sys/devices/system/cpu/cpufreq"),
            run_dir: PathBuf::from("/run/omarchy-surface-sl7"),
        }
    }
}

#[derive(Serialize, Deserialize, Default, Clone, PartialEq, Debug)]
#[serde(default)]
pub struct StateFile {
    pub last_full_ts: Option<f64>,
    pub charge_at_full: Option<f64>,
    pub upower_imported: bool,
}

struct Client {
    stream: UnixStream,
    topics: HashSet<String>,
}

struct SleepStart {
    ts: f64,
    charge: Option<f64>,
    energy: Option<f64>,
    ac: bool,
}

#[derive(Clone, Default)]
struct Snap {
    ts: f64,
    present: bool,
    bat: Battery,
    ac: bool,
    screen_on: bool,
    discharging: bool,
    charging: bool,
    full: bool,
}

pub struct App {
    pub paths: Paths,
    pub cfg: Config,
    pub rev: u64,
    bat_dir: Option<PathBuf>,
    m1: Ring,
    m15: Ring,
    acc1: Option<Acc>,
    acc15: Option<Acc>,
    rates: Rates,
    full: FullTracker,
    pub auto: Auto,
    profile: Option<String>,
    profiles: Vec<String>,
    profile_at: f64,
    snap: Snap,
    sleeps: SleepLog,
    sleep_start: Option<SleepStart>,
    clients: HashMap<u64, Client>,
    state: StateFile,
    saved_state: StateFile,
    unplug_checked: bool,
}

type ApiResult = Result<Value, (String, String)>;

fn api_err(code: &str, msg: &str) -> ApiResult {
    Err((code.to_string(), msg.to_string()))
}

/// "6h", "24h", "7d", "30d", "90m" or a number of seconds.
pub fn parse_window(v: &Value) -> Option<f64> {
    if let Some(n) = v.as_f64() {
        return if n > 0.0 { Some(n) } else { None };
    }
    let s = v.as_str()?;
    if s.len() < 2 {
        return None;
    }
    let (num, unit) = s.split_at(s.len() - 1);
    let n: f64 = num.parse().ok()?;
    let secs = match unit {
        "m" => 60.0,
        "h" => 3600.0,
        "d" => 86400.0,
        _ => return None,
    };
    if n > 0.0 {
        Some((n * secs).min(365.0 * 86400.0))
    } else {
        None
    }
}

fn opt(v: Option<f64>, f: fn(f64) -> f64) -> Value {
    match v {
        Some(x) => json!(f(x)),
        None => Value::Null,
    }
}

impl App {
    pub fn new(paths: Paths) -> App {
        let now = now_secs();
        let _ = std::fs::create_dir_all(&paths.state_dir);
        let cfg = Config::load(&paths.config);
        let mut m1 = Ring::open(&paths.state_dir.join("m1.ring"), M1_RES, M1_CAP);
        let mut m15 = Ring::open(&paths.state_dir.join("m15.ring"), M15_RES, M15_CAP);
        let sleeps = SleepLog::load(&paths.state_dir.join("sleeps.jsonl"));
        let state_path = paths.state_dir.join("state.json");
        let mut state: StateFile = std::fs::read_to_string(&state_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        if !state.upower_imported {
            // First run: seed the long-range chart from UPower's history, when readable.
            upower::import(&paths.upower_dir, &mut m15, now);
            state.upower_imported = true;
        }
        let mut full = FullTracker { last_full_ts: state.last_full_ts, charge_at_full: state.charge_at_full };
        if full.last_full_ts.is_none() {
            let a = m1.last_at_or_above(99.0, now);
            let b = m15.last_at_or_above(99.0, now);
            let best = match (a, b) {
                (Some(x), Some(y)) => Some(if x.0 >= y.0 { x } else { y }),
                (x, y) => x.or(y),
            };
            if let Some((ts, c)) = best {
                full.last_full_ts = Some(ts);
                full.charge_at_full = Some(c);
            }
        }
        let bat_dir = sys::find_battery(&paths.ps);
        let saved_state = StateFile::default();
        // Persist the seeded buckets right away.
        let _ = m1.flush();
        let _ = m15.flush();
        let mut app = App {
            paths,
            cfg,
            rev: 1,
            bat_dir,
            m1,
            m15,
            acc1: None,
            acc15: None,
            rates: Rates::default(),
            full,
            auto: Auto::default(),
            profile: None,
            profiles: Vec::new(),
            profile_at: 0.0,
            snap: Snap::default(),
            sleeps,
            sleep_start: None,
            clients: HashMap::new(),
            state,
            saved_state,
            unplug_checked: false,
        };
        app.flush();
        app
    }

    // ---- persistence -----------------------------------------------------------

    pub fn flush(&mut self) {
        let _ = self.m1.flush();
        let _ = self.m15.flush();
        self.state.last_full_ts = self.full.last_full_ts;
        self.state.charge_at_full = self.full.charge_at_full;
        if self.state != self.saved_state {
            if let Ok(text) = serde_json::to_string(&self.state) {
                let path = self.paths.state_dir.join("state.json");
                let tmp = self.paths.state_dir.join("state.json.tmp");
                if std::fs::write(&tmp, text).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
                    self.saved_state = self.state.clone();
                }
            }
        }
    }

    // ---- sampling ----------------------------------------------------------------

    fn refresh_profile(&mut self, ts: f64, force: bool) {
        if force || self.profile.is_none() || ts - self.profile_at > 300.0 {
            self.profile = sys::active_profile();
            self.profile_at = ts;
        }
        if self.profiles.is_empty() && self.profile.is_some() {
            self.profiles = sys::list_profiles();
        }
    }

    /// When the daemon starts on battery, the unplug moment is the last bucket on AC.
    fn infer_unplug(&self, now: f64, energy_full_wh: f64) -> Option<(f64, f64)> {
        let top = (now / M1_RES as f64) as i64;
        let mut i = top;
        while i > 0 && top - i < M1_CAP as i64 {
            if let Some(r) = self.m1.get(i as u32) {
                if r.ac >= 50 {
                    return Some(((i + 1) as f64 * M1_RES as f64, r.charge as f64 / 100.0 / 100.0 * energy_full_wh));
                }
            }
            i -= 1;
        }
        None
    }

    fn add_to_rings(&mut self, ts: f64, v: &SampleVals) {
        let idx1 = (ts / M1_RES as f64) as u32;
        let idx15 = (ts / M15_RES as f64) as u32;
        if self.acc1.as_ref().map(|a| a.idx) != Some(idx1) {
            self.acc1 = Some(match self.m1.get(idx1) {
                Some(r) => Acc::from_rec(&r),
                None => Acc::new(idx1),
            });
        }
        if self.acc15.as_ref().map(|a| a.idx) != Some(idx15) {
            self.acc15 = Some(match self.m15.get(idx15) {
                Some(r) => Acc::from_rec(&r),
                None => Acc::new(idx15),
            });
        }
        if let Some(a) = self.acc1.as_mut() {
            a.add(v);
            if a.to_rec().n > 0 {
                self.m1.put(a.to_rec());
            }
        }
        if let Some(a) = self.acc15.as_mut() {
            a.add(v);
            if a.to_rec().n > 0 {
                self.m15.put(a.to_rec());
            }
        }
    }

    /// One full sample: sysfs, screen, profile; history, rates, auto saver, push.
    pub fn sample(&mut self, force_profile: bool) {
        let ts = now_secs();
        let dir = match self.bat_dir.clone() {
            Some(d) => d,
            None => {
                self.snap = Snap { ts, present: false, ..Snap::default() };
                self.push_status();
                return;
            }
        };
        let bat = sys::read_battery(&dir);
        let ac = sys::ac_online(&self.paths.ps).unwrap_or(bat.status != "Discharging");
        let screen_on = sys::hypr_screen_on().unwrap_or(true);
        self.refresh_profile(ts, force_profile);
        let discharging = bat.status == "Discharging";
        let charging = bat.status == "Charging";
        let draw = if discharging { bat.power_w } else { None };
        let chg = if charging { bat.power_w } else { None };
        let full = is_full(&bat.status, bat.capacity, bat.limit_end);
        let vals = SampleVals {
            charge: bat.capacity,
            temp_c: bat.temp_c,
            volt_v: bat.voltage_v,
            dis_w: draw,
            chg_w: chg,
            screen_on,
            ac,
        };
        self.add_to_rings(ts, &vals);
        if !self.unplug_checked {
            self.unplug_checked = true;
            if discharging {
                if let Some(ef) = bat.energy_full_wh {
                    if let Some((t, e)) = self.infer_unplug(ts, ef) {
                        self.rates.seed_unplug(t, e);
                    }
                }
            }
        }
        let asleep = self.snap_ts_prev().map(|t0| self.sleeps.overlap(t0, ts)).unwrap_or(0.0);
        self.rates.update(ts, asleep, discharging, charging, draw, chg, bat.energy_now_wh);
        self.full.update(ts, full, bat.capacity);
        self.snap = Snap { ts, present: true, bat, ac, screen_on, discharging, charging, full };
        self.evaluate_auto();
        self.push_status();
    }

    /// Timestamp of the previous sample, if there was one.
    fn snap_ts_prev(&self) -> Option<f64> {
        if self.snap.present {
            Some(self.snap.ts)
        } else {
            None
        }
    }

    // ---- auto power saver -----------------------------------------------------------

    fn evaluate_auto(&mut self) {
        if !self.snap.present {
            return;
        }
        let has_saver = self.profiles.iter().any(|p| p == SAVER);
        let act = {
            let input = AutoIn {
                enabled: self.cfg.auto_saver.enabled,
                threshold: self.cfg.auto_saver.threshold as f64,
                capacity: self.snap.bat.capacity,
                on_battery: !self.snap.ac,
                profile: self.profile.as_deref(),
                has_saver,
            };
            self.auto.step(&input)
        };
        if let AutoAct::Set(p) = act {
            if sys::set_profile_ctl(&p) {
                self.profile = Some(p);
            } else {
                self.auto.set_failed();
            }
        }
    }

    pub fn on_profile(&mut self, p: Option<String>) {
        let ts = now_secs();
        match p {
            Some(p) => {
                self.profile = Some(p);
                self.profile_at = ts;
                if self.profiles.is_empty() {
                    self.profiles = sys::list_profiles();
                }
            }
            None => self.refresh_profile(ts, true),
        }
        self.evaluate_auto();
        self.push_status();
    }

    // ---- sleep ------------------------------------------------------------------------

    pub fn on_sleep(&mut self, going_down: bool) {
        let ts = now_secs();
        let bat = self.bat_dir.as_ref().map(|d| sys::read_battery(d));
        if going_down {
            if self.sleep_start.is_none() {
                let ac = sys::ac_online(&self.paths.ps).unwrap_or(false);
                self.sleep_start = Some(SleepStart {
                    ts,
                    charge: bat.as_ref().and_then(|b| b.capacity),
                    energy: bat.as_ref().and_then(|b| b.energy_now_wh),
                    ac,
                });
            }
            self.flush();
        } else {
            if let Some(start) = self.sleep_start.take() {
                if ts - start.ts >= 5.0 {
                    let sleep = Sleep {
                        start: start.ts,
                        end: ts,
                        charge_before: start.charge,
                        charge_after: bat.as_ref().and_then(|b| b.capacity),
                        energy_before_wh: start.energy,
                        energy_after_wh: bat.as_ref().and_then(|b| b.energy_now_wh),
                        ac: start.ac,
                        wake_irqs: count_wake_irqs(start.ts, ts),
                    };
                    self.sleeps.append(sleep);
                }
            }
            self.sample(true);
        }
    }

    // ---- JSON ---------------------------------------------------------------------------

    fn since_full_json(&self) -> Value {
        let s = &self.snap;
        let charge = match s.bat.capacity {
            Some(c) => c,
            None => return Value::Null,
        };
        let t = match self.full.last_full_ts {
            Some(t) => t,
            None => return Value::Null,
        };
        if s.full {
            return Value::Null;
        }
        let secs = (s.ts - t).max(0.0);
        let asleep = self.sleeps.overlap(t, s.ts).min(secs);
        json!({
            "full_ts": t.round(),
            "secs": secs.round(),
            "used_pct": round1((self.full.charge_at_full.unwrap_or(100.0) - charge).max(0.0)),
            "asleep_s": asleep.round(),
            "awake_s": (secs - asleep).round(),
            "on_ac": s.ac,
        })
    }

    pub fn status_json(&self) -> Value {
        let s = &self.snap;
        if !s.present {
            return json!({ "ts": s.ts.round(), "present": false });
        }
        let b = &s.bat;
        let health = match (b.energy_full_wh, b.energy_design_wh) {
            (Some(f), Some(d)) if d > 0.0 => Some(f / d * 100.0),
            _ => None,
        };
        let flow = if s.discharging {
            "discharging"
        } else if s.charging {
            "charging"
        } else {
            "idle"
        };
        let limit = b.limit_end.filter(|l| *l > 0 && *l < 100);
        let chg_pct_h = match (self.rates.chg_ewma, b.energy_full_wh) {
            (Some(w), Some(f)) if f > 0.0 => Some(w / f * 100.0),
            _ => None,
        };
        json!({
            "ts": s.ts.round(),
            "present": true,
            "status": b.status,
            "flow": flow,
            "ac": s.ac,
            "full": s.full,
            "charge": b.capacity.map(|c| c.round()),
            "energy_now_wh": opt(b.energy_now_wh, round2),
            "energy_full_wh": opt(b.energy_full_wh, round2),
            "energy_design_wh": opt(b.energy_design_wh, round2),
            "health_pct": opt(health, round1),
            "power_w": opt(b.power_w, round2),
            "ewma_w": opt(self.rates.dis_ewma, round2),
            "avg_since_unplug_w": opt(self.rates.avg_since_unplug(s.ts, b.energy_now_wh), round2),
            "since_unplug_s": self.rates.since_unplug_s(s.ts).map(|v| v.round()),
            "avg_awake_w_since_unplug": opt(self.rates.avg_awake_w(), round2),
            "awake_s_since_unplug": self.rates.awake_s_since_unplug().map(|v| v.round()),
            "charge_w": opt(self.rates.chg_ewma, round2),
            "charge_pct_h": opt(chg_pct_h, round1),
            "temp_c": opt(b.temp_c, round1),
            "voltage_v": opt(b.voltage_v, round2),
            "cycle_count": b.cycle_count,
            "charge_limit": limit,
            "screen_on": s.screen_on,
            "profile": self.profile,
            "profiles": self.profiles,
            "auto": {
                "enabled": self.cfg.auto_saver.enabled,
                "threshold": self.cfg.auto_saver.threshold,
                "hysteresis": crate::auto::HYSTERESIS,
                "armed": self.cfg.auto_saver.enabled && self.auto.armed && !self.auto.forced,
                "forced": self.auto.forced,
                "prev_profile": self.auto.prev,
            },
            "since_full": self.since_full_json(),
        })
    }

    fn config_json(&self) -> Value {
        json!({ "config": self.cfg, "rev": self.rev, "capabilities": { "profiles": self.profiles } })
    }

    fn history_json(&self, window_s: f64, points: usize, metrics: &[String]) -> Value {
        let now = now_secs();
        let step = window_s / points as f64;
        let ring = if step >= 900.0 { &self.m15 } else { &self.m1 };
        let from = now - window_s;
        let mut charge: Vec<Value> = Vec::with_capacity(points);
        let mut draw: Vec<Value> = Vec::with_capacity(points);
        let mut chg: Vec<Value> = Vec::with_capacity(points);
        let mut temp: Vec<Value> = Vec::with_capacity(points);
        let mut screen: Vec<Value> = Vec::with_capacity(points);
        let mut onac: Vec<Value> = Vec::with_capacity(points);
        let mut asleep: Vec<Value> = Vec::with_capacity(points);
        for c in 0..points {
            let t0 = from + c as f64 * step;
            let t1 = t0 + step;
            let col = ring.aggregate(t0, t1);
            charge.push(opt(col.charge, round1));
            draw.push(opt(col.dis_w, round2));
            chg.push(opt(col.chg_w, round2));
            temp.push(opt(col.temp, round1));
            screen.push(opt(col.screen, round2));
            onac.push(opt(col.ac, round2));
            asleep.push(json!(round2((self.sleeps.overlap(t0, t1) / step).min(1.0))));
        }
        let all: Vec<(&str, Vec<Value>)> = vec![
            ("charge", charge),
            ("draw_w", draw),
            ("charge_w", chg),
            ("temp_c", temp),
            ("screen_on", screen),
            ("on_ac", onac),
            ("asleep", asleep),
        ];
        let series: Vec<Value> = all
            .into_iter()
            .filter(|(m, _)| metrics.is_empty() || metrics.iter().any(|x| x.as_str() == *m))
            .map(|(m, v)| json!({ "metric": m, "avg": v }))
            .collect();
        let ring_name = if step >= 900.0 { "m15" } else { "m1" };
        json!({
            "window_s": window_s,
            "step_s": step.round(),
            "from": from.round(),
            "to": now.round(),
            "ring": ring_name,
            "series": series,
        })
    }

    fn details_json(&self, since: f64) -> Value {
        let now = now_secs();
        let s = &self.snap;
        // Drain by state over the last 24 h, from consecutive one-minute buckets on battery.
        let top = (now / M1_RES as f64) as i64;
        let (mut on_pct, mut on_s, mut off_pct, mut off_s) = (0.0, 0.0, 0.0, 0.0);
        for i in (top - 1440).max(1)..top {
            if let (Some(a), Some(b)) = (self.m1.get(i as u32), self.m1.get((i + 1) as u32)) {
                if a.ac >= 50 || b.ac >= 50 {
                    continue;
                }
                let d = a.charge as f64 / 100.0 - b.charge as f64 / 100.0;
                if d < 0.0 {
                    continue;
                }
                if b.screen >= 50 {
                    on_pct += d;
                    on_s += M1_RES as f64;
                } else {
                    off_pct += d;
                    off_s += M1_RES as f64;
                }
            }
        }
        let per_h = |pct: f64, secs: f64| -> Value {
            if secs >= 600.0 {
                json!(round2(pct / secs * 3600.0))
            } else {
                Value::Null
            }
        };
        let (mut sl_pct, mut sl_s) = (0.0, 0.0);
        for sl in self.sleeps.items.iter().filter(|x| x.end >= now - 86400.0 && !x.ac) {
            if let Some(d) = sl.drain_pct() {
                if d >= 0.0 {
                    sl_pct += d;
                    sl_s += sl.duration();
                }
            }
        }
        let sleep_w = self.recent_sleep_w(now);
        let asleep_left_s = match (sleep_w, s.bat.energy_now_wh) {
            (Some(w), Some(e)) if w >= 0.05 => Some(e / w * 3600.0),
            _ => None,
        };
        let today = self.m1.aggregate(since.max(now - 7.0 * 86400.0), now + 60.0).dis_w;
        let mode = crate::util::read_trim(&self.paths.run_dir.join("mode"));
        let mode_profile = crate::util::read_trim(&self.paths.run_dir.join("profile"));
        let mode_level = crate::util::read_trim(&self.paths.run_dir.join("level"));
        let cap = sys::cpu_cap(&self.paths.cpufreq).map(|(c, m)| json!({ "cap_khz": c, "max_khz": m }));
        let rails = sys::rails(&self.paths.hwmon).map(|r| {
            r.into_iter().map(|(l, w)| json!({ "label": l, "w": round2(w) })).collect::<Vec<Value>>()
        });
        let chg_pct_h = match (self.rates.chg_ewma, s.bat.energy_full_wh) {
            (Some(w), Some(f)) if f > 0.0 => Some(w / f * 100.0),
            _ => None,
        };
        json!({
            "on_battery_s": self.rates.since_unplug_s(now).map(|v| v.round()),
            "drain_screen_on_pct_h": per_h(on_pct, on_s),
            "drain_screen_off_pct_h": per_h(off_pct, off_s),
            "drain_suspended_pct_h": per_h(sl_pct, sl_s),
            "sleep_w": opt(sleep_w, round2),
            "asleep_left_s": opt(asleep_left_s, |v| v.round()),
            "today_avg_w": opt(today, round2),
            "charge_w": opt(self.rates.chg_ewma, round2),
            "charge_pct_h": opt(chg_pct_h, round1),
            "powermode": { "mode": mode, "profile": mode_profile, "level": mode_level, "cpu": cap },
            "rails": rails,
            "since_full": self.since_full_json(),
        })
    }

    /// Measured suspend drain in W over the last 7 days of on-battery sleeps of 10 minutes or
    /// more (energy used / sleep time). None when there is no usable record.
    fn recent_sleep_w(&self, now: f64) -> Option<f64> {
        let (mut wh, mut secs) = (0.0, 0.0);
        for sl in self.sleeps.items.iter().filter(|x| x.end >= now - 7.0 * 86400.0 && !x.ac) {
            if let (Some(b), Some(a)) = (sl.energy_before_wh, sl.energy_after_wh) {
                if sl.duration() >= 600.0 && b >= a {
                    wh += b - a;
                    secs += sl.duration();
                }
            }
        }
        if secs > 0.0 {
            Some(wh / (secs / 3600.0))
        } else {
            None
        }
    }

    fn sleeps_json(&self, limit: usize) -> Value {
        let items: Vec<Value> = self
            .sleeps
            .items
            .iter()
            .rev()
            .take(limit)
            .map(|s| {
                json!({
                    "start": s.start.round(),
                    "end": s.end.round(),
                    "duration_s": s.duration().round(),
                    "charge_before": s.charge_before.map(round1),
                    "charge_after": s.charge_after.map(round1),
                    "drain_pct": opt(s.drain_pct(), round1),
                    "avg_w": opt(s.avg_w(), round2),
                    "ac": s.ac,
                    "wake_irqs": s.wake_irqs,
                })
            })
            .collect();
        json!({ "items": items })
    }

    // ---- socket ---------------------------------------------------------------------------

    fn send(&mut self, client: u64, v: &Value) {
        let mut text = serde_json::to_string(v).unwrap_or_default();
        text.push('\n');
        let failed = match self.clients.get_mut(&client) {
            Some(c) => c.stream.write_all(text.as_bytes()).is_err(),
            None => false,
        };
        if failed {
            self.clients.remove(&client);
        }
    }

    fn broadcast(&mut self, topic: &str, data: Value) {
        let ids: Vec<u64> = self.clients.iter().filter(|(_, c)| c.topics.contains(topic)).map(|(id, _)| *id).collect();
        if ids.is_empty() {
            return;
        }
        let msg = json!({ "type": "push", "topic": topic, "data": data });
        for id in ids {
            self.send(id, &msg);
        }
    }

    pub fn push_status(&mut self) {
        if self.clients.is_empty() {
            return;
        }
        let s = self.status_json();
        self.broadcast("status", s);
    }

    pub fn connected(&mut self, id: u64, stream: UnixStream) {
        let _ = stream.set_write_timeout(Some(std::time::Duration::from_secs(2)));
        self.clients.insert(id, Client { stream, topics: HashSet::new() });
        let hello = json!({
            "type": "hello",
            "v": 1,
            "daemon": "sl7-batteryd",
            "version": env!("CARGO_PKG_VERSION"),
            "peer": { "can_write": true },
            "config_rev": self.rev,
        });
        self.send(id, &hello);
    }

    pub fn disconnected(&mut self, id: u64) {
        self.clients.remove(&id);
    }

    pub fn handle_line(&mut self, client: u64, line: &str) {
        let req: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => return,
        };
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let cmd = req.get("cmd").and_then(|c| c.as_str()).unwrap_or("").to_string();
        let args = req.get("args").cloned().unwrap_or(Value::Null);
        let result = self.dispatch(client, &cmd, &args);
        let resp = match result {
            Ok(data) => json!({ "type": "response", "id": id, "ok": true, "data": data }),
            Err((code, message)) => json!({ "type": "response", "id": id, "ok": false, "error": { "code": code, "message": message } }),
        };
        self.send(client, &resp);
        if cmd == "subscribe" {
            let s = self.status_json();
            let msg = json!({ "type": "push", "topic": "status", "data": s });
            self.send(client, &msg);
        }
    }

    fn dispatch(&mut self, client: u64, cmd: &str, args: &Value) -> ApiResult {
        match cmd {
            "ping" => Ok(json!({ "pong": true })),
            "subscribe" => {
                let topics: Vec<String> = args
                    .get("topics")
                    .and_then(|t| t.as_array())
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
                    .unwrap_or_default();
                if let Some(c) = self.clients.get_mut(&client) {
                    c.topics = topics.iter().cloned().collect();
                }
                Ok(json!({ "topics": topics }))
            }
            "status.get" => Ok(self.status_json()),
            "config.get" => Ok(self.config_json()),
            "config.set" => {
                let base = args.get("base_rev").and_then(|v| v.as_u64());
                if base != Some(self.rev) {
                    return api_err("conflict", "config changed since base_rev; read config.get first");
                }
                let patch = args.get("patch").cloned().unwrap_or(Value::Null);
                let mut next = self.cfg.clone();
                let changed = match next.apply_patch(&patch) {
                    Ok(c) => c,
                    Err(e) => return api_err("bad_args", &e),
                };
                if changed {
                    if let Err(e) = next.save(&self.paths.config) {
                        return api_err("io_error", &e.to_string());
                    }
                    self.cfg = next;
                    self.rev += 1;
                    self.auto.rearm();
                    let cj = self.config_json();
                    self.broadcast("config", cj);
                    self.evaluate_auto();
                    self.push_status();
                }
                Ok(self.config_json())
            }
            "history.get" => {
                let window = match args.get("window").and_then(parse_window) {
                    Some(w) => w,
                    None => return api_err("bad_args", "window must look like 6h, 24h, 7d or 30d"),
                };
                let points = args.get("points").and_then(|p| p.as_u64()).unwrap_or(80).clamp(8, 720) as usize;
                let metrics: Vec<String> = args
                    .get("metrics")
                    .and_then(|m| m.as_array())
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
                    .unwrap_or_default();
                Ok(self.history_json(window, points, &metrics))
            }
            "details.get" => {
                let since = args.get("since").and_then(|v| v.as_f64()).unwrap_or(0.0);
                Ok(self.details_json(since))
            }
            "sleeps.get" => {
                let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(10).clamp(1, 100) as usize;
                Ok(self.sleeps_json(limit))
            }
            "profile.set" => {
                let p = match args.get("profile").and_then(|v| v.as_str()) {
                    Some(p) => p.to_string(),
                    None => return api_err("bad_args", "profile is required"),
                };
                if !self.profiles.contains(&p) {
                    return api_err("bad_args", "unknown profile");
                }
                if !sys::set_profile_user(&p) {
                    return api_err("failed", "could not set the profile");
                }
                self.on_profile(Some(p));
                Ok(self.status_json())
            }
            _ => api_err("unknown_command", cmd),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows() {
        assert_eq!(parse_window(&json!("6h")), Some(21600.0));
        assert_eq!(parse_window(&json!("7d")), Some(604800.0));
        assert_eq!(parse_window(&json!("90m")), Some(5400.0));
        assert_eq!(parse_window(&json!(3600)), Some(3600.0));
        assert_eq!(parse_window(&json!("x")), None);
        assert_eq!(parse_window(&json!("0h")), None);
        assert_eq!(parse_window(&json!("5w")), None);
    }

    fn write(dir: &Path, name: &str, files: &[(&str, &str)]) {
        let d = dir.join(name);
        std::fs::create_dir_all(&d).unwrap();
        for (k, v) in files {
            std::fs::write(d.join(k), format!("{}\n", v)).unwrap();
        }
    }

    fn test_paths(tag: &str) -> Paths {
        let root = std::env::temp_dir().join(format!("sl7b-app-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ps = root.join("ps");
        write(
            &ps,
            "qcom-battmgr-bat",
            &[
                ("type", "Battery"),
                ("status", "Discharging"),
                ("capacity", "42"),
                ("energy_now", "21000000"),
                ("energy_full", "50000000"),
                ("energy_full_design", "54000000"),
                ("power_now", "-7000000"),
                ("temp", "305"),
                ("voltage_now", "15000000"),
            ],
        );
        write(&ps, "qcom-battmgr-ac", &[("type", "Mains"), ("online", "0")]);
        Paths {
            ps,
            state_dir: root.join("state"),
            config: root.join("config").join("config.json"),
            upower_dir: root.join("none"),
            hwmon: root.join("hwmon"),
            cpufreq: root.join("cpufreq"),
            run_dir: root.join("run"),
        }
    }

    #[test]
    fn sample_builds_status_and_history() {
        let paths = test_paths("a");
        let root = paths.state_dir.parent().unwrap().to_path_buf();
        let mut app = App::new(paths);
        app.sample(false);
        let s = app.status_json();
        assert_eq!(s["present"], json!(true));
        assert_eq!(s["charge"], json!(42.0));
        assert_eq!(s["flow"], json!("discharging"));
        assert_eq!(s["ac"], json!(false));
        assert_eq!(s["power_w"], json!(7.0));
        assert_eq!(s["health_pct"], json!(92.6));
        assert!(s["cycle_count"].is_null());
        assert_eq!(s["auto"]["threshold"], json!(30));
        let h = app.history_json(3600.0, 60, &["charge".to_string()]);
        let series = h["series"][0]["avg"].as_array().unwrap();
        assert_eq!(series.len(), 60);
        assert_eq!(series[59], json!(42.0));
        assert!(series[0].is_null());
        app.flush();
        let again = App::new(Paths { ..app.paths.clone() });
        let h2 = again.history_json(3600.0, 60, &[]);
        assert_eq!(h2["series"][0]["avg"][59], json!(42.0));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn protocol_roundtrip_over_the_dispatcher() {
        let paths = test_paths("b");
        let root = paths.state_dir.parent().unwrap().to_path_buf();
        let mut app = App::new(paths);
        app.sample(false);
        let r = app.dispatch(1, "config.get", &Value::Null).unwrap();
        assert_eq!(r["config"]["auto_saver"]["threshold"], json!(30));
        let rev = r["rev"].as_u64().unwrap();
        let bad = app.dispatch(1, "config.set", &json!({ "base_rev": rev + 5, "patch": {} }));
        assert_eq!(bad.unwrap_err().0, "conflict");
        let ok = app.dispatch(1, "config.set", &json!({ "base_rev": rev, "patch": { "auto_saver": { "threshold": 40 } } })).unwrap();
        assert_eq!(ok["config"]["auto_saver"]["threshold"], json!(40));
        assert_eq!(ok["rev"].as_u64().unwrap(), rev + 1);
        assert!(root.join("config").join("config.json").exists());
        let e = app.dispatch(1, "nope", &Value::Null).unwrap_err();
        assert_eq!(e.0, "unknown_command");
        let h = app.dispatch(1, "history.get", &json!({ "window": "bogus" }));
        assert_eq!(h.unwrap_err().0, "bad_args");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn since_full_reports_use_after_full() {
        let paths = test_paths("c");
        let root = paths.state_dir.parent().unwrap().to_path_buf();
        let mut app = App::new(paths);
        let now = now_secs();
        app.full.last_full_ts = Some(now - 4.0 * 3600.0);
        app.full.charge_at_full = Some(100.0);
        app.sleeps.append(Sleep {
            start: now - 3.0 * 3600.0,
            end: now - 1.0 * 3600.0,
            charge_before: Some(80.0),
            charge_after: Some(75.0),
            energy_before_wh: None,
            energy_after_wh: None,
            ac: false,
            wake_irqs: None,
        });
        app.sample(false);
        let sf = app.status_json()["since_full"].clone();
        assert!((sf["used_pct"].as_f64().unwrap() - 58.0).abs() < 0.11);
        assert!((sf["secs"].as_f64().unwrap() - 4.0 * 3600.0).abs() < 5.0);
        assert!((sf["asleep_s"].as_f64().unwrap() - 2.0 * 3600.0).abs() < 5.0);
        assert!((sf["awake_s"].as_f64().unwrap() - 2.0 * 3600.0).abs() < 5.0);
        let _ = std::fs::remove_dir_all(root);
    }
}
