//! Auto power saver: an edge-triggered state machine. Pure; the caller runs the action.
//!
//! * armed (at boot and after being released): when on battery and the charge is at or
//!   below the threshold, remember the current profile and switch to power-saver;
//! * if the user changes the profile while forced, forget the force;
//! * on AC the force is cleared (Omarchy restores its AC profile itself);
//! * if forced and the charge is back at threshold + hysteresis on battery, restore.

pub const HYSTERESIS: f64 = 5.0;
pub const SAVER: &str = "power-saver";

#[derive(Debug, Clone, PartialEq)]
pub struct Auto {
    pub armed: bool,
    pub forced: bool,
    pub prev: Option<String>,
}

impl Default for Auto {
    fn default() -> Self {
        Auto { armed: true, forced: false, prev: None }
    }
}

pub struct AutoIn<'a> {
    pub enabled: bool,
    pub threshold: f64,
    pub capacity: Option<f64>,
    pub on_battery: bool,
    pub profile: Option<&'a str>,
    pub has_saver: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AutoAct {
    None,
    Set(String),
}

impl Auto {
    /// Called when the configuration changed: allows an immediate trigger.
    pub fn rearm(&mut self) {
        if !self.forced {
            self.armed = true;
        }
    }

    /// The caller could not set the profile.
    pub fn set_failed(&mut self) {
        self.forced = false;
        self.prev = None;
        self.armed = true;
    }

    pub fn step(&mut self, i: &AutoIn) -> AutoAct {
        if !i.enabled {
            if self.forced {
                self.forced = false;
                self.armed = true;
                let prev = self.prev.take();
                if i.profile == Some(SAVER) {
                    if let Some(p) = prev {
                        return AutoAct::Set(p);
                    }
                }
            }
            return AutoAct::None;
        }
        if !i.on_battery {
            self.forced = false;
            self.prev = None;
            self.armed = true;
            return AutoAct::None;
        }
        let cap = match i.capacity {
            Some(c) => c,
            None => return AutoAct::None,
        };
        if self.forced {
            if i.profile.is_some() && i.profile != Some(SAVER) {
                // The user picked another profile: leave it alone.
                self.forced = false;
                self.prev = None;
                return AutoAct::None;
            }
            if cap >= i.threshold + HYSTERESIS {
                self.forced = false;
                self.armed = true;
                if let Some(p) = self.prev.take() {
                    return AutoAct::Set(p);
                }
            }
            return AutoAct::None;
        }
        if cap >= i.threshold + HYSTERESIS {
            self.armed = true;
        }
        if self.armed && cap <= i.threshold && i.has_saver {
            let cur = match i.profile {
                Some(p) => p,
                None => return AutoAct::None,
            };
            self.armed = false;
            if cur == SAVER {
                return AutoAct::None;
            }
            self.prev = Some(cur.to_string());
            self.forced = true;
            return AutoAct::Set(SAVER.to_string());
        }
        AutoAct::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input<'a>(cap: f64, battery: bool, profile: &'a str) -> AutoIn<'a> {
        AutoIn { enabled: true, threshold: 30.0, capacity: Some(cap), on_battery: battery, profile: Some(profile), has_saver: true }
    }

    #[test]
    fn crossing_forces_once_and_remembers() {
        let mut a = Auto::default();
        assert_eq!(a.step(&input(45.0, true, "balanced")), AutoAct::None);
        assert_eq!(a.step(&input(30.0, true, "balanced")), AutoAct::Set("power-saver".into()));
        assert!(a.forced);
        assert_eq!(a.prev.as_deref(), Some("balanced"));
        // Still at the threshold, now on the saver: nothing more to do.
        assert_eq!(a.step(&input(29.0, true, "power-saver")), AutoAct::None);
    }

    #[test]
    fn user_change_clears_force_and_does_not_retrigger() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        assert_eq!(a.step(&input(28.0, true, "performance")), AutoAct::None);
        assert!(!a.forced);
        // Not re-armed below the release level.
        assert_eq!(a.step(&input(27.0, true, "performance")), AutoAct::None);
        assert!(!a.forced);
    }

    #[test]
    fn ac_clears_force_without_restoring() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        assert_eq!(a.step(&input(31.0, false, "power-saver")), AutoAct::None);
        assert!(!a.forced && a.armed && a.prev.is_none());
    }

    #[test]
    fn restore_at_threshold_plus_hysteresis() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        assert_eq!(a.step(&input(34.0, true, "power-saver")), AutoAct::None);
        assert_eq!(a.step(&input(35.0, true, "power-saver")), AutoAct::Set("balanced".into()));
        assert!(!a.forced && a.armed);
    }

    #[test]
    fn already_on_saver_is_left_alone() {
        let mut a = Auto::default();
        assert_eq!(a.step(&input(20.0, true, "power-saver")), AutoAct::None);
        assert!(!a.forced);
    }

    #[test]
    fn rearm_allows_immediate_trigger_after_threshold_raise() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        a.step(&input(29.0, true, "balanced"));
        assert!(!a.forced);
        a.rearm();
        let mut i = input(29.0, true, "balanced");
        i.threshold = 60.0;
        assert_eq!(a.step(&i), AutoAct::Set("power-saver".into()));
    }

    #[test]
    fn disabling_while_forced_restores() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        let mut i = input(29.0, true, "power-saver");
        i.enabled = false;
        assert_eq!(a.step(&i), AutoAct::Set("balanced".into()));
        assert!(!a.forced);
    }

    #[test]
    fn no_saver_profile_means_no_action() {
        let mut a = Auto::default();
        let mut i = input(10.0, true, "balanced");
        i.has_saver = false;
        assert_eq!(a.step(&i), AutoAct::None);
    }

    #[test]
    fn failure_rearms() {
        let mut a = Auto::default();
        a.step(&input(30.0, true, "balanced"));
        a.set_failed();
        assert_eq!(a.step(&input(30.0, true, "balanced")), AutoAct::Set("power-saver".into()));
    }
}
