# Microsoft Surface Laptop 7 (Snapdragon X, romulus13/romulus15) board setup.
#
# REFERENCE COPY for upstreaming; not executed by the omarchy-surface-sl7
# package, which does the same work through files, pacman hooks and drop-ins
# so that it needs no upstream change. Intended location in Omarchy:
# install/hardware/microsoft/surface-laptop-7.sh, called from
# install/hardware/all.sh BEFORE fix-surface-keyboard.sh.
#
# Upstream (246f33a2fe, #14820) only runs fix-surface-keyboard.sh on x86
# Surface, so no guard is needed to keep its x86-only
# MODULES=(... surface_kbd intel_lpss_pci 8250_dw) list off arm64.

mkinitcpio_dir=${OMARCHY_SL7_MKINITCPIO_DIR:-/etc/mkinitcpio.conf.d}
limine_config_dir=${OMARCHY_SL7_LIMINE_CONFIG_DIR:-/etc/limine-entry-tool.d}

if omarchy-hw-aarch64-qualcomm && omarchy-hw-match 'Surface Laptop, 7th Edition'; then
  echo "Detected Microsoft Surface Laptop 7, applying board-specific support..."

  # Keyboard (SAM), display and USB-C in the initramfs.
  mkdir -p "$mkinitcpio_dir"
  cat >"$mkinitcpio_dir/zz-surface-laptop-7.conf" <<'CONF'
MODULES+=(
  surface_aggregator surface_aggregator_registry surface_aggregator_hub
  surface_hid_core surface_hid
  msm dispcc-x1e80100 gpucc-x1e80100 phy-qcom-edp panel-edp
  ps883x pmic_glink pmic_glink_altmode ucsi_glink
  qrtr i2c-hid-of
)
CONF

  # Never keep the x86 list around (fix-surface-keyboard.sh may have run).
  rm -f "$mkinitcpio_dir/surface_device_modules.conf"

  # Governor, devlink timeout, and a UKI (a bare linux entry has no device tree).
  mkdir -p "$limine_config_dir"
  cat >"$limine_config_dir/surface-laptop-7.conf" <<'CONF'
KERNEL_CMDLINE[default]+=" cpufreq.default_governor=schedutil fw_devlink.sync_state=timeout"
ENABLE_UKI=yes
CONF

  # Factory Wi-Fi/Bluetooth addresses from UEFI (valeronm/sl7-mac).
  systemctl enable sl7-wifi-mac.service
fi
