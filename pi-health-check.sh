#!/usr/bin/env bash
# =============================================================================
# pi-health-check.sh
#
# Runs hourly from cron. SILENT when everything is healthy.
# Sends an ntfy alert only when a check fails, then pings healthchecks.io
# at the end of every run (so a dead Pi is noticed by the missing ping).
#
# Usage:
#   pi-health-check.sh              normal (cron) run: no output
#   pi-health-check.sh --verbose    print the result of every check
#   pi-health-check.sh --test       send a test ntfy alert, then exit
#
# The same file runs on both Pis. Per-Pi settings live in ~/.pi-health.conf.
# =============================================================================

# NOTE: we deliberately do NOT use "set -e". If one check breaks, we still
# want the other checks (and the heartbeat ping) to run.
set -u

# Cron runs with a tiny PATH. Set a sane one so curl, vcgencmd, etc. are found.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# -----------------------------------------------------------------------------
# 1. SETTINGS YOU MIGHT WANT TO CHANGE (thresholds)
# -----------------------------------------------------------------------------
DISK_MAX_PCT=85          # alert if "/" is more than this % full
TEMP_MAX_C=75            # alert if CPU temp is above this (degrees C)
MEM_MIN_MB=100           # alert if available memory is below this (MB)
FALLOUT_MAX_HOURS=26     # alert if the fallout cron.out is older than this

DEDUPE_HOURS=24          # don't repeat the same alert within this many hours
UPDATES_DEDUPE_HOURS=168 # security-update alert: at most once per 7 days (168 h)

# Regex for SD card / power trouble in the kernel log (case-insensitive).
# Plain boot lines like "mmc0: new high speed SDHC card" do NOT match.
DMESG_PATTERN='i/o error|ext4-fs error|under-voltage|mmc[0-9]:.*(error|timeout|crc)'

# Fallout tool (Pi 1 only; switched on by FALLOUT_LOG="yes" in the conf file).
FALLOUT_FILE="/home/matt/bird-fallout-tool/logs/cron.out"

# MIGRATION SEASON for the fallout tool, as MM-DD.
# These dates DUPLICATE the tool's own logic. If you change the tool's
# season, change these too. Outside the season the tool sleeps, so a stale
# cron.out is normal and we skip the check.
SPRING_START="03-01"     # spring season: Mar 1 ...
SPRING_END="06-15"       #            ... through Jun 15
FALL_START="08-01"       # fall season:   Aug 1 ...
FALL_END="11-15"         #            ... through Nov 15

# -----------------------------------------------------------------------------
# 2. PATHS AND FLAGS (you normally don't touch these)
# -----------------------------------------------------------------------------
CONF_FILE="$HOME/.pi-health.conf"
STATE_DIR="$HOME/.pi-health-state"
ERROR_LOG="$STATE_DIR/errors.log"
HOST="$(hostname)"

VERBOSE=0
TEST=0
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=1 ;;
    --test)    TEST=1 ;;
    *) echo "Unknown option: $arg (use --verbose or --test)"; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR"

# -----------------------------------------------------------------------------
# 3. HELPER FUNCTIONS
# -----------------------------------------------------------------------------

# say "text": print only when --verbose (or --test) was given.
say() {
  if [ "$VERBOSE" -eq 1 ]; then echo "$*"; fi
}

# log_error "text": append a timestamped line to errors.log.
# This is how the script avoids failing silently.
log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$ERROR_LOG"
  say "ERROR: $*"
}

# Keep errors.log from growing forever (last 200 lines kept).
if [ -f "$ERROR_LOG" ] && [ "$(wc -l < "$ERROR_LOG")" -gt 400 ]; then
  tail -n 200 "$ERROR_LOG" > "$ERROR_LOG.tmp" && mv "$ERROR_LOG.tmp" "$ERROR_LOG"
fi

# send_alert KEY WAIT_HOURS MESSAGE
#   KEY         short name for this problem, e.g. "disk" (used for dedupe)
#   WAIT_HOURS  don't send the same KEY again within this many hours
#               (0 = always send)
#   MESSAGE     text of the notification
# On success it records the send time in $STATE_DIR/KEY.last.
# If curl fails, it logs the failure and does NOT record the time, so the
# next hourly run simply tries again.
send_alert() {
  local key="$1" wait_hours="$2" message="$3"
  local stamp="$STATE_DIR/$key.last"
  local now last
  now=$(date +%s)
  last=0
  [ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null)
  # If the stamp file holds junk, treat it as "never sent".
  case "$last" in ''|*[!0-9]*) last=0 ;; esac

  if [ $(( now - last )) -lt $(( wait_hours * 3600 )) ]; then
    say "  (alert '$key' already sent within $wait_hours h; not repeating)"
    return 0
  fi

  if [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_TOPIC:-}" ]; then
    log_error "Cannot send '$key' alert: NTFY_URL or NTFY_TOPIC missing in $CONF_FILE"
    return 1
  fi

  # -f: treat HTTP errors (4xx/5xx) as failures.  -sS: quiet but show errors.
  # -m 15: give up after 15 seconds.
  local out
  if out=$(curl -fsS -m 15 \
        -H "Title: $HOST: $key" \
        -H "Priority: high" \
        -H "Tags: warning" \
        -d "$message" \
        "${NTFY_URL%/}/$NTFY_TOPIC" 2>&1); then
    echo "$now" > "$stamp"
    say "  ALERT SENT ($key)"
  else
    log_error "ntfy send failed for '$key': $out"
    return 1
  fi
}

# float_gt A B: succeeds if A > B (handles decimals like 52.6).
float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

# -----------------------------------------------------------------------------
# 4. LOAD CONFIG
# -----------------------------------------------------------------------------
if [ ! -f "$CONF_FILE" ]; then
  log_error "Config file $CONF_FILE not found. Copy pi-health.conf.example to it."
  exit 1
fi
# shellcheck disable=SC1090
. "$CONF_FILE"

# --test: send one alert (ignoring dedupe) and quit.
if [ "$TEST" -eq 1 ]; then
  VERBOSE=1
  echo "Sending test alert to ${NTFY_URL:-?}/${NTFY_TOPIC:-?} ..."
  send_alert "test" 0 "Test alert from $HOST at $(date '+%H:%M'). If you see this, ntfy works."
  echo "Done. Check your phone. Any failure is logged in $ERROR_LOG"
  exit 0
fi

# -----------------------------------------------------------------------------
# 5. THE CHECKS (one function each)
# -----------------------------------------------------------------------------

# --- Disk: how full is "/"? --------------------------------------------------
check_disk() {
  local pct
  # df -P gives stable columns; field 5 is "Use%" like "23%". Strip the %.
  pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if [ -z "$pct" ]; then log_error "disk: could not read df output"; return; fi
  say "disk:      ${pct}% used (limit ${DISK_MAX_PCT}%)"
  if [ "$pct" -gt "$DISK_MAX_PCT" ]; then
    send_alert "disk" "$DEDUPE_HOURS" "Root disk is ${pct}% full (limit ${DISK_MAX_PCT}%)."
  fi
}

# --- Temperature -------------------------------------------------------------
check_temp() {
  local raw temp
  if ! raw=$(vcgencmd measure_temp 2>&1); then
    log_error "temp: vcgencmd failed: $raw"; return
  fi
  # raw looks like: temp=52.6'C   -> keep just the number
  temp=$(echo "$raw" | sed -n "s/^temp=\([0-9.]*\).*/\1/p")
  if [ -z "$temp" ]; then log_error "temp: could not parse '$raw'"; return; fi
  say "temp:      ${temp}C (limit ${TEMP_MAX_C}C)"
  if float_gt "$temp" "$TEMP_MAX_C"; then
    send_alert "temp" "$DEDUPE_HOURS" "CPU temperature is ${temp}C (limit ${TEMP_MAX_C}C)."
  fi
}

# --- Power / throttling ------------------------------------------------------
# vcgencmd get_throttled returns a hex number made of bit flags:
#   Bit  0 (0x1)      under-voltage RIGHT NOW
#   Bit  1 (0x2)      ARM frequency capped RIGHT NOW
#   Bit  2 (0x4)      currently throttled
#   Bit  3 (0x8)      soft temperature limit active RIGHT NOW
#   Bit 16 (0x10000)  under-voltage has occurred SINCE BOOT
#   Bit 17 (0x20000)  frequency cap has occurred since boot
#   Bit 18 (0x40000)  throttling has occurred since boot
#   Bit 19 (0x80000)  soft temperature limit has occurred since boot
# 0x0 means perfectly healthy. The "since boot" bits stay set until reboot,
# so after one brown-out you'll be reminded every 24 h until you reboot.
check_throttled() {
  local raw hex val reasons=""
  if ! raw=$(vcgencmd get_throttled 2>&1); then
    log_error "throttled: vcgencmd failed: $raw"; return
  fi
  hex="${raw#throttled=}"                  # "throttled=0x50005" -> "0x50005"
  case "$hex" in 0x[0-9a-fA-F]*) ;; *) log_error "throttled: could not parse '$raw'"; return ;; esac
  val=$(( hex ))                           # bash understands 0x... numbers
  say "throttled: $hex (healthy = 0x0)"
  if [ "$val" -ne 0 ]; then
    [ $(( val & 0x1 ))     -ne 0 ] && reasons="$reasons under-voltage-now"
    [ $(( val & 0x2 ))     -ne 0 ] && reasons="$reasons freq-capped-now"
    [ $(( val & 0x4 ))     -ne 0 ] && reasons="$reasons throttled-now"
    [ $(( val & 0x8 ))     -ne 0 ] && reasons="$reasons soft-temp-limit-now"
    [ $(( val & 0x10000 )) -ne 0 ] && reasons="$reasons under-voltage-since-boot"
    [ $(( val & 0x20000 )) -ne 0 ] && reasons="$reasons freq-cap-since-boot"
    [ $(( val & 0x40000 )) -ne 0 ] && reasons="$reasons throttled-since-boot"
    [ $(( val & 0x80000 )) -ne 0 ] && reasons="$reasons soft-temp-since-boot"
    send_alert "throttled" "$DEDUPE_HOURS" "Power/throttling flags $hex:$reasons. Check the power supply and cable."
  fi
}

# --- Memory ------------------------------------------------------------------
check_memory() {
  local kb mb
  # MemAvailable in /proc/meminfo is in kB.
  kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [ -z "$kb" ]; then log_error "memory: MemAvailable not found in /proc/meminfo"; return; fi
  mb=$(( kb / 1024 ))
  say "memory:    ${mb} MB available (min ${MEM_MIN_MB} MB)"
  if [ "$mb" -lt "$MEM_MIN_MB" ]; then
    send_alert "memory" "$DEDUPE_HOURS" "Only ${mb} MB memory available (min ${MEM_MIN_MB} MB)."
  fi
}

# --- SD card / kernel errors -------------------------------------------------
# Reading the kernel log may need root. We try, in order:
#   1. plain dmesg          (works if the system allows it)
#   2. sudo -n dmesg        (-n = never prompt; needs a sudoers rule, see README)
#   3. journalctl -k -b     (kernel messages since boot, from the journal)
check_dmesg() {
  local log="" source="" hits count
  if log=$(dmesg 2>/dev/null) && [ -n "$log" ]; then
    source="dmesg"
  elif log=$(sudo -n dmesg 2>/dev/null) && [ -n "$log" ]; then
    source="sudo dmesg"
  elif log=$(journalctl -k -b --no-pager 2>/dev/null) && [ -n "$log" ]; then
    source="journalctl -k"
  else
    log_error "dmesg: could not read the kernel log (dmesg, sudo dmesg and journalctl all failed)"
    return
  fi
  hits=$(echo "$log" | grep -Ei "$DMESG_PATTERN")
  if [ -z "$hits" ]; then count=0; else count=$(echo "$hits" | wc -l); fi
  say "dmesg:     $count matching error line(s) via $source"
  if [ "$count" -gt 0 ]; then
    # Include up to the last 3 matching lines so the alert says what happened.
    send_alert "dmesg" "$DEDUPE_HOURS" "$count kernel error line(s) (SD card/power). Last: $(echo "$hits" | tail -n 3 | tr '\n' '|')"
  fi
}

# --- Pending security updates ------------------------------------------------
# We only READ apt's list. We never run apt update or install anything.
check_updates() {
  local list total sec
  if ! list=$(apt list --upgradable 2>/dev/null); then
    log_error "updates: apt list failed"; return
  fi
  # Skip the "Listing..." header line. Security updates come from a
  # "...-security" repository, e.g. "trixie-security".
  total=$(echo "$list" | grep -c 'upgradable from')
  sec=$(echo "$list" | grep 'upgradable from' | grep -c -- '-security')
  say "updates:   $sec security (of $total total pending)"
  if [ "$sec" -ge 1 ]; then
    send_alert "updates" "$UPDATES_DEDUPE_HOURS" "$sec security update(s) pending ($total total). Run: sudo apt upgrade"
  fi
}

# --- Fallout tool log (Pi 1 only) --------------------------------------------
in_season() {
  local today
  today=$(date +%m-%d)    # e.g. "11-14"; same-width strings compare correctly
  # ">" or "==" gives us ">=" for strings; "!" ">" gives us "<=".
  if { [[ "$today" > "$SPRING_START" || "$today" == "$SPRING_START" ]] && [[ ! "$today" > "$SPRING_END" ]]; } ||
     { [[ "$today" > "$FALL_START"   || "$today" == "$FALL_START"   ]] && [[ ! "$today" > "$FALL_END"   ]]; }; then
    return 0
  fi
  return 1
}

check_fallout() {
  if [ "${FALLOUT_LOG:-no}" != "yes" ]; then
    say "fallout:   skipped (FALLOUT_LOG is not 'yes' on this Pi)"; return
  fi
  if ! in_season; then
    say "fallout:   skipped (outside migration season)"; return
  fi
  if [ ! -f "$FALLOUT_FILE" ]; then
    say "fallout:   $FALLOUT_FILE is MISSING"
    send_alert "fallout" "$DEDUPE_HOURS" "Fallout log $FALLOUT_FILE does not exist."
    return
  fi
  local age_h
  # stat -c %Y = last-modified time in seconds since 1970.
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$FALLOUT_FILE") ) / 3600 ))
  say "fallout:   cron.out is ${age_h} h old (max ${FALLOUT_MAX_HOURS} h)"
  if [ "$age_h" -ge "$FALLOUT_MAX_HOURS" ]; then
    send_alert "fallout" "$DEDUPE_HOURS" "Fallout cron.out not updated for ${age_h} h (max ${FALLOUT_MAX_HOURS} h). Did the cron job stop?"
  fi
}

# -----------------------------------------------------------------------------
# 6. RUN EVERYTHING
# -----------------------------------------------------------------------------
check_disk
check_temp
check_throttled
check_memory
check_dmesg
check_updates
check_fallout

# -----------------------------------------------------------------------------
# 7. HEARTBEAT
# Always last, so it also proves the script ran to the end. If this Pi dies,
# healthchecks.io notices the missing ping and alerts you.
# -----------------------------------------------------------------------------
if [ -n "${HC_PING_URL:-}" ]; then
  if out=$(curl -fsS -m 10 --retry 3 -o /dev/null "$HC_PING_URL" 2>&1); then
    say "heartbeat: ping sent"
  else
    log_error "healthchecks ping failed: $out"
  fi
else
  say "heartbeat: skipped (HC_PING_URL not set)"
fi

exit 0
