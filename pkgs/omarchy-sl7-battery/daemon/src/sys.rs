//! Readers for sysfs, Hyprland and power-profiles-daemon.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::util::{read_f64, read_trim, run, run_env, run_ok};

pub const PS_DIR: &str = "/sys/class/power_supply";

#[derive(Debug, Clone, Default)]
pub struct Battery {
    pub status: String,
    pub capacity: Option<f64>,
    pub energy_now_wh: Option<f64>,
    pub energy_full_wh: Option<f64>,
    pub energy_design_wh: Option<f64>,
    /// Magnitude of power_now in watts (the sign is not trusted; `status` says the direction).
    pub power_w: Option<f64>,
    pub temp_c: Option<f64>,
    pub voltage_v: Option<f64>,
    pub cycle_count: Option<u64>,
    pub limit_end: Option<u32>,
    pub limit_start: Option<u32>,
}

/// The internal battery: qcom-battmgr-bat if present, else the first Battery supply that
/// is not a peripheral (scope Device).
pub fn find_battery(ps: &Path) -> Option<PathBuf> {
    let preferred = ps.join("qcom-battmgr-bat");
    if preferred.is_dir() {
        return Some(preferred);
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(ps).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    dirs.sort();
    dirs.into_iter().find(|d| {
        read_trim(&d.join("type")).as_deref() == Some("Battery") && read_trim(&d.join("scope")).as_deref() != Some("Device")
    })
}

pub fn read_battery(dir: &Path) -> Battery {
    let f = |name: &str| read_f64(&dir.join(name));
    let mut b = Battery {
        status: read_trim(&dir.join("status")).unwrap_or_default(),
        capacity: f("capacity"),
        energy_now_wh: f("energy_now").map(|v| v / 1e6),
        energy_full_wh: f("energy_full").map(|v| v / 1e6),
        energy_design_wh: f("energy_full_design").map(|v| v / 1e6),
        power_w: f("power_now").map(|v| v.abs() / 1e6),
        temp_c: f("temp").map(|v| v / 10.0),
        voltage_v: f("voltage_now").map(|v| v / 1e6),
        cycle_count: f("cycle_count").map(|v| v as u64).filter(|v| *v > 0),
        limit_end: f("charge_control_end_threshold").map(|v| v as u32),
        limit_start: f("charge_control_start_threshold").map(|v| v as u32),
    };
    // Charge-based gauges: approximate energy with the present voltage.
    if b.energy_full_wh.is_none() {
        if let Some(v) = b.voltage_v {
            b.energy_full_wh = f("charge_full").map(|c| c / 1e6 * v);
            b.energy_now_wh = f("charge_now").map(|c| c / 1e6 * v);
            b.energy_design_wh = f("charge_full_design").map(|c| c / 1e6 * v);
        }
    }
    if b.capacity.is_none() {
        if let (Some(n), Some(full)) = (b.energy_now_wh, b.energy_full_wh) {
            if full > 0.0 {
                b.capacity = Some((n / full * 100.0).clamp(0.0, 100.0));
            }
        }
    }
    b
}

/// True when any Mains or USB supply reports online. None when the machine has no such
/// supply at all.
pub fn ac_online(ps: &Path) -> Option<bool> {
    let mut have = false;
    for e in std::fs::read_dir(ps).ok()?.filter_map(|e| e.ok()) {
        let d = e.path();
        let ty = match read_trim(&d.join("type")) {
            Some(t) => t,
            None => continue,
        };
        if !(ty == "Mains" || ty.starts_with("USB")) {
            continue;
        }
        let online = match read_trim(&d.join("online")) {
            Some(o) => o,
            None => continue,
        };
        have = true;
        if online == "1" {
            return Some(true);
        }
    }
    if have {
        Some(false)
    } else {
        None
    }
}

fn hypr_instance() -> Option<String> {
    if let Ok(s) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        if !s.is_empty() {
            return Some(s);
        }
    }
    let rt = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let mut best: Option<(std::time::SystemTime, String)> = None;
    for e in std::fs::read_dir(Path::new(&rt).join("hypr")).ok()?.filter_map(|e| e.ok()) {
        let p = e.path();
        if !p.join(".socket.sock").exists() {
            continue;
        }
        let m = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
        let name = e.file_name().to_string_lossy().to_string();
        if best.as_ref().map(|(t, _)| m > *t).unwrap_or(true) {
            best = Some((m, name));
        }
    }
    best.map(|(_, n)| n)
}

/// Whether any monitor is lit (DPMS on). None when Hyprland cannot be asked.
pub fn hypr_screen_on() -> Option<bool> {
    let sig = hypr_instance()?;
    let out = run_env("hyprctl", &["monitors", "-j"], &[("HYPRLAND_INSTANCE_SIGNATURE", sig.as_str())], Duration::from_millis(1500))?;
    parse_screen_on(&out)
}

pub fn parse_screen_on(json: &str) -> Option<bool> {
    let v: Value = serde_json::from_str(json).ok()?;
    let arr = v.as_array()?;
    Some(arr.iter().any(|m| {
        m.get("dpmsStatus").and_then(|x| x.as_bool()).unwrap_or(true) && !m.get("disabled").and_then(|x| x.as_bool()).unwrap_or(false)
    }))
}

const PPD_NAMES: [(&str, &str); 2] = [
    ("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles"),
    ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"),
];

pub fn active_profile() -> Option<String> {
    for (name, path) in PPD_NAMES {
        if let Some(out) = run("busctl", &["--system", "get-property", name, path, name, "ActiveProfile"], Duration::from_millis(1500)) {
            if let Some(p) = parse_busctl_string(&out) {
                return Some(p);
            }
        }
    }
    run("powerprofilesctl", &["get"], Duration::from_secs(3)).map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// `s "balanced"` -> balanced
pub fn parse_busctl_string(out: &str) -> Option<String> {
    let a = out.find('"')?;
    let b = out.rfind('"')?;
    if b > a {
        Some(out[a + 1..b].to_string())
    } else {
        None
    }
}

pub fn list_profiles() -> Vec<String> {
    run("powerprofilesctl", &["list"], Duration::from_secs(4)).map(|t| parse_profiles(&t)).unwrap_or_default()
}

/// Reads the profile names out of `powerprofilesctl list`, in the order it prints them
/// reversed (power-saver, balanced, performance).
pub fn parse_profiles(text: &str) -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for line in text.lines() {
        let t = line.trim().trim_start_matches('*').trim();
        if let Some(name) = t.strip_suffix(':') {
            if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
                v.push(name.to_string());
            }
        }
    }
    v.reverse();
    v
}

pub fn set_profile_ctl(profile: &str) -> bool {
    run_ok("powerprofilesctl", &["set", profile], Duration::from_secs(5))
}

/// A user's choice goes through Omarchy so it is remembered per power source.
pub fn set_profile_user(profile: &str) -> bool {
    if run_ok("omarchy-powerprofiles-set", &["autodetect", profile], Duration::from_secs(6)) {
        return true;
    }
    set_profile_ctl(profile)
}

/// Rail powers from the qcom_pld_power hwmon: (label, watts). CPU clusters are summed.
pub fn rails(hwmon_root: &Path) -> Option<Vec<(String, f64)>> {
    let mut dir = None;
    for e in std::fs::read_dir(hwmon_root).ok()?.filter_map(|e| e.ok()) {
        if read_trim(&e.path().join("name")).as_deref() == Some("qcom_pld_power") {
            dir = Some(e.path());
            break;
        }
    }
    let dir = dir?;
    let mut vals: Vec<(String, f64)> = Vec::new();
    for n in 1..=16 {
        let label = match read_trim(&dir.join(format!("power{}_label", n))) {
            Some(l) => l,
            None => continue,
        };
        if let Some(uw) = read_f64(&dir.join(format!("power{}_average", n))) {
            vals.push((label, uw / 1e6));
        }
    }
    let cpu: Vec<f64> = vals.iter().filter(|(l, _)| l.starts_with("CPU_CLUSTER")).map(|(_, w)| *w).collect();
    let mut out: Vec<(String, f64)> = Vec::new();
    if !cpu.is_empty() {
        out.push(("CPU".to_string(), cpu.iter().sum()));
    }
    for (l, w) in &vals {
        if l == "GPU" || l == "SYS" {
            out.push((l.clone(), *w));
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// (current cap, hardware max) of cpufreq policy0 in kHz.
pub fn cpu_cap(cpufreq: &Path) -> Option<(f64, f64)> {
    let p = cpufreq.join("policy0");
    Some((read_f64(&p.join("scaling_max_freq"))?, read_f64(&p.join("cpuinfo_max_freq"))?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profiles_parse_in_order() {
        let text = "  performance:\n    CpuDriver:\tplaceholder\n    PlatformDriver:\tplaceholder\n\n* balanced:\n    CpuDriver:\tplaceholder\n\n  power-saver:\n    CpuDriver:\tplaceholder\n";
        assert_eq!(parse_profiles(text), vec!["power-saver", "balanced", "performance"]);
        let two = "* balanced:\n    CpuDriver: x\n\n  power-saver:\n    CpuDriver: x\n";
        assert_eq!(parse_profiles(two), vec!["power-saver", "balanced"]);
    }

    #[test]
    fn busctl_string() {
        assert_eq!(parse_busctl_string("s \"power-saver\"\n"), Some("power-saver".to_string()));
        assert_eq!(parse_busctl_string("nothing"), None);
    }

    #[test]
    fn screen_state() {
        assert_eq!(parse_screen_on(r#"[{"name":"eDP-1","dpmsStatus":true}]"#), Some(true));
        assert_eq!(parse_screen_on(r#"[{"name":"eDP-1","dpmsStatus":false}]"#), Some(false));
        assert_eq!(parse_screen_on(r#"[{"dpmsStatus":false},{"dpmsStatus":true}]"#), Some(true));
        assert_eq!(parse_screen_on("garbage"), None);
    }

    fn fake_supply(root: &Path, name: &str, files: &[(&str, &str)]) {
        let d = root.join(name);
        std::fs::create_dir_all(&d).unwrap();
        for (k, v) in files {
            std::fs::write(d.join(k), format!("{}\n", v)).unwrap();
        }
    }

    #[test]
    fn battery_and_ac_from_fake_sysfs() {
        let root = std::env::temp_dir().join(format!("sl7b-ps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        fake_supply(
            &root,
            "qcom-battmgr-bat",
            &[
                ("type", "Battery"),
                ("status", "Discharging"),
                ("capacity", "62"),
                ("energy_now", "30000000"),
                ("energy_full", "50000000"),
                ("energy_full_design", "54000000"),
                ("power_now", "-6500000"),
                ("temp", "312"),
                ("voltage_now", "15200000"),
                ("cycle_count", "0"),
            ],
        );
        fake_supply(&root, "qcom-battmgr-ac", &[("type", "Mains"), ("online", "0")]);
        fake_supply(&root, "qcom-battmgr-usb", &[("type", "USB"), ("online", "0")]);
        let dir = find_battery(&root).unwrap();
        let b = read_battery(&dir);
        assert_eq!(b.status, "Discharging");
        assert_eq!(b.capacity, Some(62.0));
        assert!((b.power_w.unwrap() - 6.5).abs() < 1e-9);
        assert!((b.temp_c.unwrap() - 31.2).abs() < 1e-9);
        assert!((b.energy_full_wh.unwrap() - 50.0).abs() < 1e-9);
        assert_eq!(b.cycle_count, None);
        assert_eq!(ac_online(&root), Some(false));
        fake_supply(&root, "qcom-battmgr-usb", &[("type", "USB"), ("online", "1")]);
        assert_eq!(ac_online(&root), Some(true));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn capacity_falls_back_to_energy_ratio() {
        let root = std::env::temp_dir().join(format!("sl7b-ps2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        fake_supply(&root, "BAT0", &[("type", "Battery"), ("status", "Charging"), ("energy_now", "25000000"), ("energy_full", "50000000")]);
        let b = read_battery(&root.join("BAT0"));
        assert_eq!(b.capacity, Some(50.0));
        assert_eq!(find_battery(&root), Some(root.join("BAT0")));
        let _ = std::fs::remove_dir_all(&root);
    }
}
