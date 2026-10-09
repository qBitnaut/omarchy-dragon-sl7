//! ~/.config/omarchy-sl7-battery/config.json, written only through config.set.

use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const THRESHOLD_MIN: u8 = 10;
pub const THRESHOLD_MAX: u8 = 60;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct AutoSaverCfg {
    pub enabled: bool,
    pub threshold: u8,
}

impl Default for AutoSaverCfg {
    fn default() -> Self {
        AutoSaverCfg { enabled: true, threshold: 30 }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Config {
    pub version: u32,
    pub auto_saver: AutoSaverCfg,
}

impl Default for Config {
    fn default() -> Self {
        Config { version: 1, auto_saver: AutoSaverCfg::default() }
    }
}

impl Config {
    pub fn load(path: &Path) -> Config {
        let mut cfg: Config = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        cfg.auto_saver.threshold = cfg.auto_saver.threshold.clamp(THRESHOLD_MIN, THRESHOLD_MAX);
        cfg.version = 1;
        cfg
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        {
            let mut f = std::fs::File::create(&tmp)?;
            let text = serde_json::to_string_pretty(self).unwrap_or_default();
            f.write_all(text.as_bytes())?;
            f.write_all(b"\n")?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, path)
    }

    /// Merges a patch such as {"auto_saver": {"threshold": 40}}. Validates everything
    /// before changing anything. Returns whether the configuration changed.
    pub fn apply_patch(&mut self, patch: &Value) -> Result<bool, String> {
        let obj = patch.as_object().ok_or("patch must be an object")?;
        let mut next = self.clone();
        for (k, v) in obj {
            match k.as_str() {
                "auto_saver" => {
                    let a = v.as_object().ok_or("auto_saver must be an object")?;
                    for (ak, av) in a {
                        match ak.as_str() {
                            "enabled" => {
                                next.auto_saver.enabled = av.as_bool().ok_or("auto_saver.enabled must be a boolean")?;
                            }
                            "threshold" => {
                                let n = av.as_u64().ok_or("auto_saver.threshold must be an integer")?;
                                if n < THRESHOLD_MIN as u64 || n > THRESHOLD_MAX as u64 {
                                    return Err(format!("auto_saver.threshold must be {}-{}", THRESHOLD_MIN, THRESHOLD_MAX));
                                }
                                next.auto_saver.threshold = n as u8;
                            }
                            other => return Err(format!("unknown key auto_saver.{}", other)),
                        }
                    }
                }
                other => return Err(format!("unknown key {}", other)),
            }
        }
        let changed = next != *self;
        *self = next;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn defaults() {
        let c = Config::default();
        assert!(c.auto_saver.enabled);
        assert_eq!(c.auto_saver.threshold, 30);
    }

    #[test]
    fn patch_validates_and_merges() {
        let mut c = Config::default();
        assert_eq!(c.apply_patch(&json!({"auto_saver": {"threshold": 45}})), Ok(true));
        assert_eq!(c.auto_saver.threshold, 45);
        assert!(c.auto_saver.enabled);
        assert_eq!(c.apply_patch(&json!({"auto_saver": {"threshold": 45}})), Ok(false));
        assert!(c.apply_patch(&json!({"auto_saver": {"threshold": 99}})).is_err());
        assert!(c.apply_patch(&json!({"auto_saver": {"enabled": "yes"}})).is_err());
        assert!(c.apply_patch(&json!({"bogus": 1})).is_err());
        // A rejected patch changes nothing, even when part of it was valid.
        assert!(c.apply_patch(&json!({"auto_saver": {"enabled": false, "threshold": 5}})).is_err());
        assert!(c.auto_saver.enabled);
    }

    #[test]
    fn save_and_load_roundtrip() {
        let dir = std::env::temp_dir().join(format!("sl7b-cfg-{}", std::process::id()));
        let path = dir.join("config.json");
        let mut c = Config::default();
        c.auto_saver.threshold = 20;
        c.save(&path).unwrap();
        assert_eq!(Config::load(&path), c);
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(Config::load(&path), Config::default());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
