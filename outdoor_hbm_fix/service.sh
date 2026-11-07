#!/system/bin/sh
# Outdoor / HDR brightness fix for the MintOS r8q port (v16).
#
# Defects being worked around:
#  1. Auto-brightness curve stops at 2953 lux / ~380 nits and HBM never engages,
#     so sunlight is capped far below the panel's 800 nit ceiling.
#  2. Outdoor mode asks for 486 (1.9058824) but the max=1.0/hbm=0 clamp makes
#     Samsung's scaler map that to ~26, so enabling it makes the screen darker.
#  3. HDR playback is pinned at 0.91930795 (380 nits) and the brightness slider
#     does nothing while it lasts, because the port leaves the framework's HDR
#     ratio splines unconfigured.
#
# v13 and earlier wrote the sysfs node while DisplayPowerController was still
# animating towards its own (much lower) target. The two writers interleaved,
# which is what "flickering while it climbs to full brightness" really was: in a
# 1.5 s window the framework overwrote our value 238 times.
#
# v14 takes the framework out of the picture first:
#   * switch to manual brightness and park the framework slider at its maximum,
#     which makes the framework's own target 255 and stops it animating down;
#   * wait until the sysfs value stops changing (framework animator finished);
#   * only then ramp up, in one uncontested monotonic sweep;
#   * while holding, correct only a *stable* wrong value, so a late framework
#     write causes one correction instead of an oscillation.
#
# Engage/release are debounced so a flickering lux reading (a torch, a passing
# cloud, a hand) cannot make the module flap between states.
#
# v15/v16 add the HDR path and the escape hatch:
#   * only the newest SurfaceFlinger HDR event counts, and only when the layer is
#     at least 700 px wide -- the dump is a history, so trusting all of it made
#     the module believe HDR was still playing long after the video ended;
#   * moving the brightness slider, or turning auto-brightness back on, makes the
#     module stand down immediately instead of fighting the user.

B=/sys/class/backlight/panel0-backlight/brightness
LUXF=/sys/class/sensors/light_sensor/lux
MAX=486
SAFE=255
LOG=/data/local/tmp/outdoor_hbm.log
SAVEF=/data/adb/modules/outdoor_hbm_fix/saved_settings

ENGAGE_LUX=8000
HOLD_LUX=3000
ENGAGE_N=2
RELEASE_N=6

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 65536 ] && : > "$LOG"

read_brt() {
  v=$(cat "$B" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  echo "$v"
}

read_lux() {
  raw=$(cat "$LUXF" 2>/dev/null)
  lux=${raw%%,*}
  case "$lux" in ''|*[!0-9]*) lux="?" ;; esac
  echo "$lux"
}

getset() {
  v=$(settings get system "$1" 2>/dev/null)
  case "$v" in ''|null) v="?" ;; esac
  echo "$v"
}

# The auto-brightness flag the user actually had, which force_max() replaces.
saved_mode() {
  [ -f "$SAVEF" ] || { echo ""; return 0; }
  sed -n 1p "$SAVEF" 2>/dev/null
}

# The brightness DisplayPowerController believes it has applied, converted back
# to the sysfs scale (its native float 0..1.9058824 maps linearly onto 0..486).
# Needed because the framework skips the write when its target has not changed,
# so a value we injected stays on the panel and the framework never corrects it.
fw_brt() {
  st=$(dumpsys display 2>/dev/null | grep -m1 'mBrightnessState=' | sed 's/.*mBrightnessState=//' | tr -d ' \r')
  case "$st" in ''|*[!0-9.]*) echo ""; return 0 ;; esac
  awk -v s="$st" 'BEGIN{v=int(s*255+0.5); if(v>486)v=486; if(v<0)v=0; print v}'
}

# This port's HDR brightness policy pins DisplayPowerController at 0.91930795
# (= 380 nits) and ignores the slider entirely, because the HDR ratio splines the
# framework needs are not configured. Only a genuinely large HDR layer counts:
# SurfaceFlinger also reports HDR thumbnails and progress bars, which are a few
# dozen pixels wide and must not be mistaken for playback.
hdr_active() {
  # Only the newest event describes the current state; the dump is a history and
  # still contains full-size entries from videos watched earlier.
  line=$(dumpsys SurfaceFlinger --hdr 2>/dev/null | grep 'numHdrLayers(' | tail -1)
  case "$line" in
    *'numHdrLayers(0)'*) return 1 ;;
    *'numHdrLayers('*) ;;
    *) return 1 ;;
  esac
  w=$(echo "$line" | sed -n 's/.*size(\([0-9][0-9]*\)x.*/\1/p')
  case "$w" in ''|*[!0-9]*) return 1 ;; esac
  [ "$w" -ge 700 ]
}

# Park the user's brightness settings so the framework stops writing, and
# remember the originals so they can be handed back on release.
force_max() {
  if [ ! -f "$SAVEF" ]; then
    { getset screen_brightness_mode; getset screen_brightness; } > "$SAVEF"
  fi
  settings put system screen_brightness_mode 0
  settings put system screen_brightness "$SAFE"
  # Re-assert once: a dropped write here would look like the user grabbing the
  # slider and would make the module back off straight away.
  [ "$(getset screen_brightness)" != "$SAFE" ] && settings put system screen_brightness "$SAFE"
  return 0
}

restore_settings() {
  [ -f "$SAVEF" ] || return 0
  m=$(sed -n 1p "$SAVEF" 2>/dev/null)
  s=$(sed -n 2p "$SAVEF" 2>/dev/null)
  rm -f "$SAVEF"
  # Only put the slider back if it still holds the value we parked it at; if the
  # user moved it in the meantime that is their choice, not ours to undo.
  cur=$(getset screen_brightness)
  case "$s" in ''|*[!0-9]*) s="" ;; esac
  if [ -n "$s" ] && [ "$cur" = "$SAFE" ]; then
    settings put system screen_brightness "$s"
  fi
  case "$m" in ''|*[!0-9]*) m="" ;; esac
  [ -n "$m" ] && settings put system screen_brightness_mode "$m"
  return 0
}

# Block until the sysfs value has been unchanged for ~350 ms (or ~2.5 s max).
wait_idle() {
  last=-1; n=0; t=0
  while [ "$t" -lt 70 ]; do
    c=$(read_brt)
    if [ "$c" = "$last" ]; then n=$((n+1)); else n=0; last=$c; fi
    [ "$n" -ge 10 ] && return 0
    usleep 20000
    t=$((t+1))
  done
  return 0
}

ramp_to() {
  tgt=$1
  cur=$(read_brt)
  [ "$cur" -eq "$tgt" ] && return 0
  if [ "$cur" -lt "$tgt" ]; then
    step=$(( (tgt - cur) / 10 )); [ "$step" -lt 4 ] && step=4
    v=$cur
    while [ "$v" -lt "$tgt" ]; do
      v=$((v + step)); [ "$v" -gt "$tgt" ] && v=$tgt
      echo "$v" > "$B"; usleep 20000
    done
  else
    step=$(( (cur - tgt) / 10 )); [ "$step" -lt 4 ] && step=4
    v=$cur
    while [ "$v" -gt "$tgt" ]; do
      v=$((v - step)); [ "$v" -lt "$tgt" ] && v=$tgt
      echo "$v" > "$B"; usleep 20000
    done
  fi
  return 0
}

own=0
pending=0
pending_n=0
sync_n=0
sync_last=-1
poll_n=0
hdr=0
hdr_last=0
hdr_off_n=0
suppress=0
supp_trigger=""

# Optional override: write 0..486 into this file to change the HDR brightness
# target (0 disables the HDR boost entirely).
HDR_MAX=$(cat /data/adb/modules/outdoor_hbm_fix/hdr_cap 2>/dev/null)
case "$HDR_MAX" in ''|*[!0-9]*) HDR_MAX=486 ;; esac
[ "$HDR_MAX" -gt 486 ] && HDR_MAX=486

log "service started (v16, hdr_cap=$HDR_MAX)"
restore_settings

while true; do
  usleep 400000

  if [ "$(getprop debug.tracing.screen_state)" = "4" ]; then
    if [ "$own" -ne 0 ]; then ramp_to "$SAFE"; restore_settings; own=0; fi
    pending_n=0; continue
  fi

  outdoor=$(getset display_outdoor_mode)
  auto=$(getset screen_brightness_mode)
  lux=$(read_lux)

  # Refresh the HDR state only every few iterations; the SurfaceFlinger dump is
  # the single most expensive probe in this loop. Leaving HDR needs the state to
  # stay clear for three polls so a video shrinking into a thumbnail as it scrolls
  # away cannot end the boost early and start it again on the next one.
  poll_n=$((poll_n+1))
  if [ "$HDR_MAX" -gt 0 ] && { [ "$own" -eq 0 ] || [ "$hdr_last" -eq 1 ]; } && [ "$poll_n" -ge 3 ]; then
    poll_n=0
    if hdr_active; then
      hdr=1; hdr_off_n=0
    else
      hdr_off_n=$((hdr_off_n+1))
      [ "$hdr_off_n" -ge 3 ] && hdr=0
    fi
    hdr_last=$hdr
  else
    hdr=$hdr_last
  fi

  tgt=$MAX
  kind=""
  if [ "$outdoor" = "1" ]; then
    target=1; kind="outdoor"; reason="outdoor"
  elif [ "$hdr" -eq 1 ]; then
    target=1; kind="hdr"; tgt=$HDR_MAX; reason="hdr"
  elif [ "$own" -eq 0 ]; then
    if [ "$auto" = "1" ] && [ "$lux" != "?" ] && [ "$lux" -ge "$ENGAGE_LUX" ]; then
      target=1; kind="lux"; reason="lux=$lux"
    else
      target=0; reason="idle"
    fi
  else
    am=$(saved_mode)
    case "$am" in ''|*[!0-9]*) am=$auto ;; esac
    if [ "$lux" = "?" ]; then
      target=1; kind="lux"; reason="lux unknown"
    elif [ "$am" = "1" ]; then
      if [ "$lux" -ge "$HOLD_LUX" ]; then target=1; kind="lux"; else target=0; fi
      reason="lux=$lux"
    else
      target=0; reason="auto off"
    fi
  fi

  # Escape hatch: once the user moves the slider or turns auto-brightness back on
  # they own the brightness for the rest of *this* trigger. A different trigger
  # (e.g. they then switch Outdoor mode on) is a fresh, explicit request, so it is
  # honoured immediately instead of staying suppressed.
  if [ "$suppress" -eq 1 ]; then
    cur_trig=""
    if [ "$outdoor" = "1" ]; then cur_trig="outdoor"
    elif [ "$hdr" -eq 1 ]; then cur_trig="hdr"
    elif [ "$auto" = "1" ] && [ "$lux" != "?" ] && [ "$lux" -ge "$HOLD_LUX" ]; then cur_trig="lux"
    fi
    if [ -z "$cur_trig" ] || [ "$cur_trig" != "$supp_trigger" ]; then
      suppress=0
    else
      target=0; kind=""; reason="suppressed($cur_trig)"
    fi
  fi

  if [ "$target" -ne "$own" ]; then
    if [ "$target" = "$pending" ]; then pending_n=$((pending_n+1)); else pending=$target; pending_n=1; fi
    if [ "$target" -eq 1 ]; then need=$ENGAGE_N; else need=$RELEASE_N; fi
  else
    pending=$own; pending_n=0; need=0
  fi

  if [ "$need" -gt 0 ] && [ "$pending_n" -ge "$need" ]; then
    if [ "$target" -eq 1 ]; then
      log "engage ($reason)"
      force_max
      wait_idle
      ramp_to "$tgt"
      own=1
      pending_n=0
    else
      cur=$(read_brt)
      log "release ($reason, from $cur)"
      restore_settings
      usleep 400000
      # Hand the panel back at the value the framework thinks it has, otherwise a
      # skipped framework write leaves our 486 on the panel and the display stays
      # at 800 nits (or, after a former release, stuck dim while HDR asks for it).
      fw=$(fw_brt)
      case "$fw" in ''|*[!0-9]*) fw=$SAFE ;; esac
      ramp_to "$fw"
      own=0
      pending_n=0
    fi
    continue
  fi

  # Safety net: if the panel and the framework's belief have disagreed for a
  # while with nothing changing, the framework almost certainly skipped a write.
  # Requiring the value to be stable keeps normal brightness animations intact.
  if [ "$own" -eq 0 ]; then
    sync_n=$((sync_n+1))
    if [ "$sync_n" -ge 5 ]; then
      sync_n=0
      c=$(read_brt)
      fw=$(fw_brt)
      if [ -n "$fw" ] && [ "$fw" -gt 0 ] && [ "$c" -eq "$sync_last" ]; then
        d=$((c - fw)); [ "$d" -lt 0 ] && d=$((0 - d))
        if [ "$d" -gt 6 ]; then
          log "sync $c -> $fw"
          echo "$fw" > "$B"
        fi
      fi
      sync_last=$c
    fi
  else
    sync_n=0
  fi

  if [ "$own" -eq 1 ] && [ "$pending_n" -eq 0 ]; then
    lastc=-1; bad=0; i=0; uov=0
    while [ "$i" -lt 6 ]; do
      # The parked slider value is ours; anything else means the user took over,
      # and fighting them would just make the screen bounce between two levels.
      cm=$(getset screen_brightness_mode)
      cs=$(getset screen_brightness)
      if [ "$cm" = "1" ] || { [ "$cs" != "?" ] && [ "$cs" != "$SAFE" ]; }; then
        uov=1; break
      fi
      c=$(read_brt)
      if [ "$c" -ne "$tgt" ]; then
        if [ "$c" = "$lastc" ]; then bad=$((bad+1)); else bad=0; fi
        if [ "$bad" -ge 4 ]; then echo "$tgt" > "$B"; log "corrected (was $c)"; bad=0; fi
        lastc=$c
      else
        lastc=$tgt; bad=0
      fi
      usleep 200000
      i=$((i+1))
    done
    if [ "$uov" -eq 1 ]; then
      log "user override (mode=$cm sbrt=$cs) - standing down"
      # Undo the parking (auto-brightness flag) but keep the slider where the
      # user just put it: restore_settings only rewrites that if it is still ours.
      restore_settings
      own=0; suppress=1; supp_trigger="$kind"; pending_n=0
      continue
    fi
  fi
done