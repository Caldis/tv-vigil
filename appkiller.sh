#!/system/bin/sh
# tv-vigil — Auto-kill rogue background apps on Android TV
# Runs on the TV itself via: nohup sh /data/local/tmp/appkiller.sh &
# Repo: https://github.com/Caldis/tv-vigil

# ============================================================
# CONFIG — edit this section to match your setup
# ============================================================

# Seconds an app must be in background before being killed
THRESHOLD=180

# How often to check (seconds)
CHECK_INTERVAL=60

# Write stats file every N cycles
STATS_INTERVAL=10

# Apps to monitor — add/remove package names as needed
# Find package names: adb shell pm list packages -3
ROGUE_APPS="
com.cibn.tv
com.ktcp.video
com.hunantv.market
com.gitvdemo.video
com.newtv.cboxtv
com.xiaodianshi.tv.yst
com.wasu.wasutvcs
com.jd.smartservicetwo
com.sony.dangbeimarket
com.qterics.da.product
top.yogiczy.mytv.tv
"

# ============================================================
# PATHS — usually no need to change
# ============================================================
BASE_DIR="/data/local/tmp"
TRACK_DIR="$BASE_DIR/bg_track"
LOGFILE="$BASE_DIR/appkiller.log"
STATSFILE="$BASE_DIR/appkiller_stats"
LOCKDIR="$BASE_DIR/appkiller.lock"
PIDFILE="$LOCKDIR/pid"
MAX_LOG_LINES=500
MAX_LOG_BYTES=51200

# ============================================================
# INTERNAL — do not edit below
# ============================================================
stat_cycles=0
stat_kills=0
stat_skips=0
stat_start=$(date +%s 2>/dev/null)
writing_stats=0

log() {
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

trim_log() {
  [ ! -f "$LOGFILE" ] && return
  size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
  lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$size" -gt "$MAX_LOG_BYTES" ] || [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n 200 "$LOGFILE" > "$LOGFILE.$$"
    mv "$LOGFILE.$$" "$LOGFILE"
  fi
}

get_fg_pkg() {
  dumpsys window windows 2>/dev/null | awk '
    /mCurrentFocus=|mFocusedApp=/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /[[:alnum:]_.]+\//) {
          split($i, a, "/")
          gsub(/[^a-zA-Z0-9._]/, "", a[1])
          if (a[1] != "") { print a[1]; exit }
        }
      }
    }'
}

is_pkg_running() {
  pidof "$1" >/dev/null 2>&1 && return 0
  ps -A -o NAME 2>/dev/null | grep -qF "$1:" && return 0
  return 1
}

inc_app_kills() {
  kf="$TRACK_DIR/.kills.$1"
  prev=$(cat "$kf" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0;; esac
  echo $((prev + 1)) > "$kf"
}

write_stats() {
  [ "$writing_stats" -eq 1 ] && return
  writing_stats=1
  now=$(date +%s)
  uptime_s=$((now - stat_start))
  uptime_m=$((uptime_s / 60))
  {
    echo "# appkiller stats (updated $(date '+%m-%d %H:%M:%S'))"
    echo "pid=$$"
    echo "started=$stat_start"
    echo "uptime_min=$uptime_m"
    echo "total_cycles=$stat_cycles"
    echo "total_kills=$stat_kills"
    echo "total_skips=$stat_skips"
    echo "---per-app-kills---"
    for pkg in $ROGUE_APPS; do
      kf="$TRACK_DIR/.kills.$pkg"
      cnt=$(cat "$kf" 2>/dev/null)
      case "$cnt" in ''|*[!0-9]*) cnt=0;; esac
      [ "$cnt" -gt 0 ] && echo "$pkg=$cnt"
    done
  } > "$STATSFILE.$$"
  mv "$STATSFILE.$$" "$STATSFILE"
  writing_stats=0
}

cleanup() {
  log "stopping pid=$$"
  write_stats
  rm -rf "$LOCKDIR" 2>/dev/null
}

# --- startup checks ---

now_test=$(date +%s 2>/dev/null)
case "$now_test" in
  ''|*[!0-9]*) echo "ERROR: date +%s not supported"; exit 1;;
esac

if mkdir "$LOCKDIR" 2>/dev/null; then
  :
elif [ -f "$PIDFILE" ]; then
  old_pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "already running (pid $old_pid)"
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { echo "cannot acquire lock"; exit 1; }
else
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { echo "cannot acquire lock"; exit 1; }
fi
echo $$ > "$PIDFILE"
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

mkdir -p "$TRACK_DIR"
log "=== started pid=$$ threshold=${THRESHOLD}s interval=${CHECK_INTERVAL}s ==="

# --- main loop ---

while true; do
  fg=$(get_fg_pkg)
  now=$(date +%s)
  cycle_running=0
  cycle_bg=0
  cycle_killed=0

  if [ -z "$fg" ]; then
    stat_skips=$((stat_skips + 1))
    stat_cycles=$((stat_cycles + 1))
    log "cycle #$stat_cycles skip (no fg)"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  for pkg in $ROGUE_APPS; do
    if ! is_pkg_running "$pkg"; then
      rm -f "$TRACK_DIR/$pkg"; continue
    fi
    cycle_running=$((cycle_running + 1))

    if [ "$pkg" = "$fg" ]; then
      rm -f "$TRACK_DIR/$pkg"; continue
    fi
    cycle_bg=$((cycle_bg + 1))

    tf="$TRACK_DIR/$pkg"
    if [ ! -f "$tf" ]; then
      echo "$now" > "$tf"; continue
    fi

    first=$(cat "$tf" 2>/dev/null)
    case "$first" in
      ''|*[!0-9]*) echo "$now" > "$tf"; continue;;
    esac

    elapsed=$((now - first))
    if [ "$elapsed" -ge "$THRESHOLD" ]; then
      log "KILL $pkg (bg ${elapsed}s)"
      am force-stop "$pkg"
      rm -f "$tf"
      cycle_killed=$((cycle_killed + 1))
      stat_kills=$((stat_kills + 1))
      inc_app_kills "$pkg"
    fi
  done

  stat_cycles=$((stat_cycles + 1))
  log "cycle #$stat_cycles fg=$fg run=$cycle_running bg=$cycle_bg killed=$cycle_killed"

  remainder=$((stat_cycles % STATS_INTERVAL))
  if [ "$remainder" -eq 0 ]; then
    write_stats
    trim_log
  fi

  sleep "$CHECK_INTERVAL"
done
