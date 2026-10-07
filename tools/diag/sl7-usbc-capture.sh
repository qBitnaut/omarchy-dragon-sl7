#!/usr/bin/env bash
# sl7-usbc-capture.sh: trace USB-C plug/unplug on the SL7 to find why a device
# sometimes never enumerates. Run as root on the Surface Laptop 7:
#   sudo bash sl7-usbc-capture.sh [controller]   (default a600000.usb)
# Plug and unplug when prompted until a plug fails, then answer the prompts.
# Writes /var/tmp/usbc-<time>.tgz. Removes its kprobes and trace settings on exit.
set +e
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

CTL=${1:-a600000.usb}
D=/var/tmp/usbc-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"
T=/sys/kernel/tracing; G=/sys/kernel/debug; DD=/proc/dynamic_debug/control
[[ -e $DD ]] || DD=$G/dynamic_debug/control

xh() {
  XH=$(basename "$(ls -d /sys/bus/platform/devices/$CTL/xhci-hcd.*.auto 2>/dev/null | head -1)")
  BUSES=$(cd /sys/bus/platform/devices/$XH 2>/dev/null && ls -d usb[0-9]* | tr -dc '0-9 \n' | xargs)
}
xh
UC=$(ls -d $G/usb/ucsi/*/ 2>/dev/null | head -1)
{ uname -r; cat /proc/cmdline; echo "ctl=$CTL xhci=$XH buses=$BUSES ucsi=$UC"; } > "$D/info.txt"

QS='module ps883x;module pmic_glink_altmode;module pmic_glink;module ucsi_glink;module typec_ucsi;module typec;module phy_qcom_eusb2_repeater;file phy-qcom-qmp-combo.c;file dwc3-qcom.c;file drivers/usb/core/hub.c'
IFS=';'; for q in $QS; do echo "$q +pt" > "$DD" 2>/dev/null || echo "dyndbg no match: $q"; done; unset IFS

snap() {
  local o=$D/$1; mkdir -p "$o"
  for p in $G/usb/xhci/$XH/ports/port*; do echo "${p##*/}: $(cat "$p/portsc")"; done > "$o/portsc.txt" 2>&1
  { for n in 0 1; do
      for f in orientation power_role data_role power_operation_mode; do
        echo "port$n/$f: $(cat /sys/class/typec/port$n/$f)"
      done
    done
    ls -d /sys/class/typec/port*-*
    if [[ -n $UC ]]; then
      for c in 0x10012 0x20012; do
        echo "$c" > "${UC}command"
        echo "CONNECTOR_STATUS($c)=$(cat "${UC}response") vbus_voltage=$(cat "${UC}vbus_voltage")"
      done
    fi; } > "$o/typec.txt" 2>&1
  for c in clk3 clk4 tcsr_usb2_1_clkref_en; do
    echo "$c prep=$(cat $G/clk/$c/clk_prepare_count) en=$(cat $G/clk/$c/clk_enable_count)"
  done > "$o/clk.txt" 2>&1
  grep -iE 'rtmr|l2b|l3d|l14b|l1j|l2j|l3j' $G/regulator/regulator_summary > "$o/regulators.txt" 2>&1
  for r in $G/regmap/*-0008; do echo "== $r"; head -3 "$r/registers"; done > "$o/ps883x-regs.txt" 2>&1
  for r in $G/regmap/*-07; do
    echo "== $r"
    for a in fd08 fd46 fd51 fd54 fd57 fde8 fded; do grep -i "^$a:" "$r/registers"; done
  done > "$o/eusb2-rptr.txt" 2>&1
  for d in /sys/bus/platform/devices/$CTL /sys/bus/platform/devices/$XH $(for b in $BUSES; do echo /sys/bus/usb/devices/usb$b; done); do
    echo "${d##*/} control=$(cat "$d/power/control") status=$(cat "$d/power/runtime_status")"
  done > "$o/rpm.txt" 2>&1
  lsusb -t > "$o/lsusb-t.txt" 2>&1
  grep -H . /sys/class/power_supply/*usb*/{online,voltage_now,current_now} > "$o/psy.txt" 2>/dev/null
}

EVS=""
cleanup() {
  echo 0 > $T/tracing_on
  cp $T/trace "$D/trace.txt" 2>/dev/null
  [[ -n $DM ]] && kill "$DM" 2>/dev/null
  echo 0 > $T/events/enable
  for e in $EVS; do echo 0 > "$T/events/$e/filter"; done
  echo > $T/kprobe_events
  IFS=';'; for q in $QS; do echo "$q -pt" > "$DD" 2>/dev/null; done; unset IFS
  tar czf "$D.tgz" -C /var/tmp "${D##*/}" && echo "DONE: $D.tgz"
}
trap cleanup EXIT

echo 0 > $T/tracing_on; echo > $T/trace; echo 8192 > $T/buffer_size_kb
echo 0 > $T/events/enable; echo > $T/kprobe_events
while read -r k; do
  echo "$k" >> $T/kprobe_events 2>/dev/null || echo "kprobe failed: $k"
done <<'EOF'
p:sl7/ps_sw ps883x:ps883x_sw_set orient=%x1:u32
p:sl7/ps_rt ps883x:ps883x_retimer_set alt=+0(%x1):x64 mode=+8(%x1):u64
r:sl7/ps_rt_ret ps883x:ps883x_retimer_set ret=$retval:s32
p:sl7/qmp_sw qmp_combo_typec_switch_set orient=%x1:u32
p:sl7/qmp_mux qmp_combo_typec_mux_set mode=+8(%x1):u64
p:sl7/typec_orient typec_set_orientation orient=%x1:u32
p:sl7/alt_work pmic_glink_altmode:pmic_glink_altmode_worker
p:sl7/rptr_init phy_qcom_eusb2_repeater:eusb2_repeater_init
p:sl7/rptr_mode phy_qcom_eusb2_repeater:eusb2_repeater_set_mode mode=%x1:s32
EOF
echo 1 > $T/events/sl7/enable 2>/dev/null

ev() { EVS="$EVS $1"; echo "$2" > "$T/events/$1/filter"; echo 1 > "$T/events/$1/enable" || echo "event failed: $1"; }
ev regmap/regmap_reg_write 'name ~ "*-0008" || (name ~ "*-07" && reg >= 0xfd00 && reg <= 0xfdff)'
ev regmap/regmap_reg_read 'name ~ "*-0008"'
F=$(for b in $BUSES; do printf 'busnum == %s || ' "$b"; done); F=${F% || }
for e in xhci_handle_port_status xhci_hub_status_data xhci_portsc_writel; do ev xhci-hcd/$e "$F"; done
for e in clk_prepare clk_unprepare clk_enable clk_disable; do
  ev clk/$e 'name == "clk3" || name == "clk4" || name == "tcsr_usb2_1_clkref_en"'
done
for e in regulator_enable_complete regulator_disable_complete; do ev regulator/$e 'name ~ "VREG_RTMR*"'; done
echo 1 > $T/events/ucsi/enable 2>/dev/null

dmesg -w > "$D/dmesg.txt" & DM=$!
echo 1 > $T/tracing_on
snap 0-idle
echo "Start with nothing plugged into the port under test ($CTL)."

n=1
while :; do
  read -rp "[$n] plug the stick in, wait 10 s, Enter (q = stop) " a </dev/tty
  [[ $a == q ]] && break
  snap "$n-plug"
  if grep -q '|__' "$D/$n-plug/lsusb-t.txt"; then
    echo "    detected"
  else
    echo "    NOT detected: this is the capture we need"
    read -rp "    Enter to restart the controller with the stick still in (s = skip) " a </dev/tty
    if [[ $a != s ]]; then
      DRV=$(readlink -f /sys/bus/platform/devices/$CTL/driver)
      echo "$CTL" > "$DRV/unbind"; sleep 2; echo "$CTL" > "$DRV/bind"; sleep 8; xh
      snap "$n-after-rebind"
    fi
  fi
  read -rp "[$n] eject and unplug it, wait 5 s, Enter " _ </dev/tty
  snap "$n-unplug"
  n=$((n + 1))
done

read -rp "Optional: plug a USB 2 only device (mouse/keyboard via C adapter), wait 10 s, Enter (s = skip) " a </dev/tty
[[ $a != s ]] && snap usb2dev
