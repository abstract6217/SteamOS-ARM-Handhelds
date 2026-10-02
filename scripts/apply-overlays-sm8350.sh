#!/usr/bin/env bash
# Apply the REDMAGIC 6 (SM8350) kernel and overlay onto a SteamOS ARM rootfs.
# Run by make-steamos-sm8350.sh, as root.
#
# The rootfs is the one every chip shares (make-steamos-sm8650.sh builds it,
# or a release image carries it), so only these change, all REDMAGIC-only:
#   - this kernel's modules + the NX669J firmware (the other kernels' modules
#     are dropped: they cannot load on this kernel)
#   - sm8350-overlay (gamescope panel profile, Wi-Fi/BT addresses and board
#     data, lights, sleep default, /home on the root partition)
#   - release rootfs (v1.2 and older) only: the shared files that know about
#     the REDMAGIC 6 in this tree are patched in place, and the later shared
#     fixes that apply to the phone are brought in (see below)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${STEAMOS_WORK:-/work}"
R="${STEAMOS_ROOTFS:-${WORKDIR}/rootfs-sm8350}"
OVL="${ROOT}/steamos-overlay"
SM8350_OVL="${ROOT}/sm8350-overlay"
KOUT="$(readlink -f "${KERNEL_OUT:-${WORKDIR}/kernel-sm8350/output/current}")"
KREL="$(basename "$KOUT")"
LOG="${WORKDIR}/sm8350-apply.log"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" | tee -a "$LOG"; }

[[ "${EUID}" -eq 0 ]] || die "run as root (rootfs ownership)"
[[ -x "$R/usr/bin/bash" ]] || die "missing rootfs at $R"
[[ -f "$KOUT/boot/boot.img" && -d "$KOUT/modules/$KREL" && -d "$KOUT/firmware" ]] \
  || die "no SM8350 kernel at $KOUT (external-and-mods/kernel-sm8350/build.sh)"

: >"$LOG"
log "== $(date -Iseconds) apply REDMAGIC 6 mods into $R"

# ---------------------------------------------------------------------------
# 1. Kernel modules & firmware. The kernel itself goes to boot_a/boot_b, not
#    into the rootfs (no FAT boot partition on the phone).
# ---------------------------------------------------------------------------
log "== kernel ${KREL}: modules + NX669J firmware"
rm -rf "$R"/usr/lib/modules/*
cp -a "$KOUT/modules/$KREL" "$R/usr/lib/modules/$KREL"
rsync -a "$KOUT/firmware/" "$R/usr/lib/firmware/"
rm -f "$R/boot/KERNEL" "$R/boot/KERNEL.md5"
mkdir -p "$R/opt/steamos-sm8650"
find "$R/opt/steamos-sm8650" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
mkdir -p "$R/opt/steamos-sm8650/$KREL"
cp -a "$KOUT/config-$KREL" "$KOUT/dtbs" "$R/opt/steamos-sm8650/$KREL/"

# ---------------------------------------------------------------------------
# 2. sm8350-overlay. Units match the DT model / compatible, but the overlay
#    also replaces home.mount, so it only ever goes into this rootfs.
# ---------------------------------------------------------------------------
log "== sm8350-overlay (REDMAGIC 6)"
cp -r --no-preserve=mode,ownership "$SM8350_OVL/." "$R/"
find "$R/etc/gamescope/scripts" -name 'redmagic6*' -exec chmod 0644 {} +
chmod 0644 "$R/etc/systemd/system/home.mount"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants" "$R/var/lib/steamos-arm/firmware"
for s in nx669j-wlan-bdf nx669j-bt-addr nx669j-lights; do
  chmod 0755 "$R/usr/lib/steamos-arm/$s"
done
for s in nx669j-wlan-bdf nx669j-bt-addr nx669j-sleep-default nx669j-lights; do
  chmod 0644 "$R/usr/lib/systemd/system/$s.service"
  ln -sfn "../$s.service" "$R/usr/lib/systemd/system/multi-user.target.wants/$s.service"
done

# ---------------------------------------------------------------------------
# 3. Release rootfs: the shared files that know about the REDMAGIC 6 in this
#    tree are older there. They are patched in place rather than replaced
#    with this tree's copies, which may expect files the release does not
#    have. Each step is a no-op on a rootfs built from this tree.
# ---------------------------------------------------------------------------
log "== shared files: REDMAGIC 6 bits"
python3 - "$R/usr/lib/konkr/konkrd" "$R/usr/lib/systemd/system/konkrd.service" <<'PY'
import sys
d, svc = sys.argv[1], sys.argv[2]
s = open(d).read()
# The fan is Nubia's MCU (nx669j_fan hwmon), not a DT pwm-fan.
if "nx669j_fan" not in s:
    old = 'if rd(f"{d}/name") == "pwmfan":'
    if old not in s:
        sys.exit("konkrd: fan lookup not found, update this script")
    s = s.replace(old, 'if rd(f"{d}/name") in ("pwmfan", "nx669j_fan"):', 1)
# Kernel s2idle: the power key press that woke the phone must not put it
# straight back to sleep (konkrd's wake grace only knew konkr-standby).
if "CLOCK_BOOTTIME" not in s:
    init = "        last_standby = 0.0\n"
    poll = "            keys = self.keys.poll(timeout, self.touch)\n"
    if init not in s or poll not in s:
        sys.exit("konkrd: key loop not found, update this script")
    s = s.replace(init, init +
        "        sleep_offset = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()\n", 1)
    s = s.replace(poll, poll +
        "            offset = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()\n"
        "            if offset - sleep_offset > 0.5:\n"
        "                last_standby = time.monotonic()      # resumed from s2idle\n"
        "            sleep_offset = offset\n", 1)
# No full-speed fan burst on power off: the failsafe is for restarts and
# crashes, the phone is off a few seconds after a shutdown stops konkrd.
if "def shutting_down" not in s:
    old = "    def stop(self, *_):\n        self.fan.failsafe_now()\n"
    if old not in s:
        sys.exit("konkrd: stop handler not found, update this script")
    s = s.replace(old,
        "    def stop(self, *_):\n"
        "        if shutting_down():\n"
        "            log(\"stopped (shutdown, fan left as is)\")\n"
        "            sys.exit(0)\n"
        "        self.fan.failsafe_now()\n", 1)
    s = s.replace("\n# ------------------------------------------------------------------ gpu ----\n",
        "\ndef shutting_down() -> bool:\n"
        "    try:\n"
        "        r = subprocess.run([\"systemctl\", \"is-system-running\"], capture_output=True,\n"
        "                           text=True, timeout=2)\n"
        "        return r.stdout.strip() == \"stopping\"\n"
        "    except (OSError, subprocess.SubprocessError):\n"
        "        return False\n"
        "\n\n# ------------------------------------------------------------------ gpu ----\n", 1)
    if "def shutting_down" not in s:
        sys.exit("konkrd: gpu section not found, update this script")
open(d, "w").write(s)
s = open(svc).read()
if "nx669j_fan" not in s:
    old = '[ "$(cat $d/name 2>/dev/null)" = pwmfan ] && echo 255 > $d/pwm1;'
    if old not in s:
        sys.exit("konkrd.service: failsafe not found, update this script")
    s = s.replace(old, 'case "$(cat $d/name 2>/dev/null)" in pwmfan|nx669j_fan) echo 255 > $d/pwm1;; esac;', 1)
if "is-system-running" not in s:
    old = "ExecStopPost=/bin/sh -c 'for d in"
    if old not in s:
        sys.exit("konkrd.service: failsafe not found, update this script")
    s = s.replace(old, "ExecStopPost=/bin/sh -c '[ \"$(systemctl is-system-running 2>/dev/null)\" = stopping ] && exit 0; for d in", 1)
# v1.2 only starts konkrd on the models it knows.
old = '"KONKR Pocket FIT|AYANEO Pocket S2"'
if "REDMAGIC 6" not in s and old in s:
    s = s.replace(old, '"KONKR Pocket FIT|AYANEO Pocket S2|REDMAGIC 6"', 1)
open(svc, "w").write(s)
PY

# Its own UCM (Nubia/NX669J), no Odin 2 codec controls.
sed -i 's/"KONKR Pocket FIT|AYANEO Pocket S2" \/sys/"KONKR Pocket FIT|AYANEO Pocket S2|REDMAGIC 6" \/sys/' \
  "$R/usr/lib/steamos/sm8550-audio-pipewire"

# The REDMAGIC card ("sm8250 - REDMAGIC 6") is set up by its UCM when
# WirePlumber opens it. Unmatched, audio-setup sat out its whole 20 s card
# wait on every boot while WirePlumber waited on it.
aus="$R/usr/lib/steamos/sm8550-audio-setup"
if [[ -f "$aus" ]] && ! grep -q 'REDMAGIC' "$aus"; then
  grep -q '^if ! wait_card; then$' "$aus" || die "sm8550-audio-setup: card wait not found, update this script"
  sed -i '/^if ! wait_card; then$/i\
# REDMAGIC 6: its UCM does everything when WirePlumber opens the card.\
if grep -qa "REDMAGIC 6" /sys/firmware/devicetree/base/model 2>/dev/null; then\
  exit 0\
fi\
' "$aus"
fi

# v1.2's 55-konkr-speaker.conf matches every HiFi Speaker sink, so the Pocket
# FIT tuning (220 Hz high-pass + 8 dB limiter) ran on the MAX98937 speakers
# too: thin and pumping.
spk="$R/etc/wireplumber/wireplumber.conf.d/55-konkr-speaker.conf"
if [[ -f "$spk" ]] && ! grep -q 'SM8650-APS2' "$spk"; then
  sed -i 's|matches = \[ { node.name = "alsa_output.platform-sound.HiFi__Speaker__sink" } \]|matches = [ { node.name = "alsa_output.platform-sound.HiFi__Speaker__sink" alsa.card_name = "SM8650-APS2" } ]|' "$spk"
  grep -q 'SM8650-APS2' "$spk" || die "55-konkr-speaker.conf: match not found, update this script"
fi

python3 - "$R/usr/lib/steamos/steamos-sm8550-expand-home" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "REDMAGIC 6" not in s:
    anchor = 'if [[ -f "$STAMP" ]]; then\n  log "marker ${STAMP} present — skip"\n  exit 0\nfi\n'
    if anchor not in s:
        sys.exit("expand-home: stamp check not found, update this script")
    s = s.replace(anchor, anchor + '''
# REDMAGIC 6: SteamOS fills the UFS userdata partition, /home is a directory
# on it and x-systemd.growfs grows the root. Never repartition that disk.
if grep -qa "REDMAGIC 6" /sys/firmware/devicetree/base/model 2>/dev/null; then
  log "REDMAGIC 6: no home partition by design (root grows via x-systemd.growfs) — skip"
  touch "$STAMP"
  exit 0
fi
''', 1)
    open(p, "w").write(s)
PY

# v1.2: the low-res flicker hotfix (hotfixes/v1.2-lowres-flicker.sh), since
# the phone gets no in-place updates.
if grep -q -- '^  --force-windows-fullscreen$' "$R/usr/lib/steamos/gamescope-session" 2>/dev/null; then
  log "== v1.2 hotfix: low-res flicker"
  sed -i '/^  --force-windows-fullscreen$/d' "$R/usr/lib/steamos/gamescope-session"
fi

# Self-contained script: LE pads need the adapter powered through mgmt.
install -m0755 "$OVL/usr/lib/steamos/sm8550-bluetooth-setup" \
  "$R/usr/lib/steamos/sm8550-bluetooth-setup"

# ---------------------------------------------------------------------------
# 4. Release rootfs: fixes the other devices got after v1.2, for the parts
#    of them the REDMAGIC 6 shares. Each step is a no-op on a newer rootfs.
# ---------------------------------------------------------------------------
log "== shared fixes from after the release"
# Steam starts every game with the Frame's renderpass optimizer (tuned for
# its Adreno 750) and eye-tracked foveation layers. No headset here: drop
# both, the loader only warns they're missing (as on the other images).
mkdir -p "$R/usr/share/vulkan/explicit_layer.d.frame"
for _l in VkLayer_VALVE_rpo.json VkLayer_VALVE_fdm_injection.json; do
  if [[ -f "$R/usr/share/vulkan/explicit_layer.d/$_l" ]]; then
    mv -f "$R/usr/share/vulkan/explicit_layer.d/$_l" "$R/usr/share/vulkan/explicit_layer.d.frame/"
  fi
done

# konkr-focusfix: games that minimise behind Quick Access come back, and a
# game whose focus bounces while it opens no longer hangs.
install -m0755 "$ROOT/sm8650-overlay/usr/lib/konkr/konkr-focusfix" \
  "$R/usr/lib/konkr/konkr-focusfix"

# Decky v3.2.10-pre1: v3.2.9's bundled Python lacks http.server, socketserver
# and configparser, so plugin backends that import them crashed (SteamGridDB).
# Handheld Control (was KONKR Control) only shows what the device has: no
# Pocket FIT MCU link, buttons or power LED on the phone.
HOME_DST="$R/home/steamos"
DECKY_VERSION=v3.2.10-pre1
DECKY_LOADER="${ROOT}/external-and-mods/Decky/loader/PluginLoader-${DECKY_VERSION}"
if [[ -d "$HOME_DST/homebrew/services" && "$(cat "$HOME_DST/homebrew/services/.loader.version" 2>/dev/null)" != "$DECKY_VERSION" ]]; then
  if [[ ! -s "$DECKY_LOADER" ]]; then
    mkdir -p "${DECKY_LOADER%/*}"
    curl -fL -o "$DECKY_LOADER.part" \
      "https://github.com/SteamDeckHomebrew/decky-loader/releases/download/${DECKY_VERSION}/PluginLoader" &&
      mv "$DECKY_LOADER.part" "$DECKY_LOADER"
  fi
  [[ -s "$DECKY_LOADER" ]] || die "Decky loader ${DECKY_VERSION} missing and download failed"
  install -m0755 "$DECKY_LOADER" "$HOME_DST/homebrew/services/PluginLoader"
  printf '%s' "$DECKY_VERSION" >"$HOME_DST/homebrew/services/.loader.version"
fi
HC_SRC="${ROOT}/external-and-mods/Decky/sm8650/konkr-control"
HC_DST="$HOME_DST/homebrew/plugins/konkr-control"
if [[ -d "$HC_DST" ]]; then
  rm -rf "$HC_DST"; mkdir -p "$HC_DST/dist"
  install -m0644 "$HC_SRC/plugin.json" "$HC_SRC/main.py" "$HC_DST/"
  [[ -f "$HC_SRC/package.json" ]] && install -m0644 "$HC_SRC/package.json" "$HC_DST/"
  install -m0644 "$HC_SRC/dist/index.js" "$HC_DST/dist/"
fi
[[ -d "$HOME_DST/homebrew" ]] && chown -R 1000:1000 "$HOME_DST/homebrew"

log "== done (kernel ${KREL})"
