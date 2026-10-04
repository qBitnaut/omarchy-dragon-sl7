-- omarchy-surface-sl7: never let the X1E80100-Romulus sound card use the
-- "pro-audio" profile.
--
-- 1. select-profile: after a stored/preferred profile is chosen and before it
--    is applied, replace "pro-audio" with the best other profile. This stops
--    a previously stored Pro Audio choice from being restored at boot.
-- 2. device-params-changed: if something (pavucontrol, wpctl, pw-cli) sets
--    Pro Audio on a running card, switch back to the best other profile.
--
-- SPDX-License-Identifier: MIT

cutils = require ("common-utils")
log = Log.open_topic ("s-omarchy-sl7")

local function is_guarded_card (device)
  local props = device.properties
  for _, key in ipairs ({ "alsa.card_name", "alsa.long_card_name",
      "device.nick", "device.description", "device.name" }) do
    local value = props[key]
    if value and (value:find ("X1E80100", 1, true) or value:find ("Romulus", 1, true)) then
      return true
    end
  end
  return false
end

-- Highest-priority profile that is neither off nor pro-audio and not
-- unavailable; falls back to off.
local function best_safe_profile (device)
  local best, off = nil, nil
  for p in device:iterate_params ("EnumProfile") do
    local profile = cutils.parseParam (p, "EnumProfile")
    if profile then
      if profile.name == "off" then
        off = profile
      elseif profile.name ~= "pro-audio" and profile.available ~= "no" then
        if best == nil or profile.priority > best.priority then
          best = profile
        end
      end
    end
  end
  return best or off
end

SimpleEventHook {
  name = "omarchy-surface-sl7/replace-pro-audio",
  after = { "device/find-stored-profile", "device/find-preferred-profile",
            "device/find-best-profile" },
  before = "device/apply-profile",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-profile" },
    },
  },
  execute = function (event)
    local selected = event:get_data ("selected-profile")
    if not selected or selected.name ~= "pro-audio" then
      return
    end
    local device = event:get_subject ()
    if not is_guarded_card (device) then
      return
    end
    local safe = best_safe_profile (device)
    if safe then
      log:warning (device, "refusing pro-audio profile on speaker card, using " .. safe.name)
      event:set_data ("selected-profile", safe)
    end
  end
}:register ()

SimpleEventHook {
  name = "omarchy-surface-sl7/revert-pro-audio",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "Profile" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    if not is_guarded_card (device) then
      return
    end
    for p in device:iterate_params ("Profile") do
      local active = cutils.parseParam (p, "Profile")
      if active and active.name == "pro-audio" then
        local safe = best_safe_profile (device)
        if safe then
          log:warning (device, "pro-audio selected on speaker card, reverting to " .. safe.name)
          device:set_param ("Profile", Pod.Object {
            "Spa:Pod:Object:Param:Profile", "Profile",
            index = tonumber (safe.index),
          })
        end
        return
      end
    end
  end
}:register ()
