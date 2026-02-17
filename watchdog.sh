#!/bin/sh
# tv-vigil watchdog — ensures appkiller.sh stays alive on the TV
# Runs on a LAN server (Mac/Linux) via crontab every 5 minutes
# Crontab: */5 * * * * /bin/sh /path/to/watchdog.sh

# ============================================================
# CONFIG — edit this section to match your setup
# ============================================================

# ADB binary path (macOS Homebrew: /opt/homebrew/bin/adb, Linux: /usr/bin/adb)
ADB="/opt/homebrew/bin/adb"

# Android TV IP and ADB port
TV_IP="192.168.1.209"
TV_PORT="5555"
TV="${TV_IP}:${TV_PORT}"

# Path to appkiller.sh on this machine (for pushing to TV)
LOCAL_SCRIPT="$(cd "$(dirname "$0")" && pwd)/appkiller.sh"

# Remote path on the TV
REMOTE_SCRIPT="/data/local/tmp/appkiller.sh"

# Watchdog log file
LOGFILE="$(cd "$(dirname "$0")" && pwd)/watchdog.log"
MAX_LOG_LINES=200

# ============================================================
# INTERNAL — do not edit below
# ============================================================

log() {
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOGFILE"
  lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n 100 "$LOGFILE" > "$LOGFILE.tmp"
    mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}

try_connect() {
  conn=$($ADB connect "$TV" 2>&1)
  case "$conn" in
    *"connected"*|*"already"*) return 0;;
  esac
  return 1
}

# connect with retry
if ! try_connect; then
  $ADB kill-server >/dev/null 2>&1
  sleep 1
  $ADB start-server >/dev/null 2>&1
  if ! try_connect; then
    log "FAIL connect"
    exit 1
  fi
fi

# check TV reachable
if ! $ADB -s "$TV" shell echo ok >/dev/null 2>&1; then
  log "FAIL unreachable"
  exit 1
fi

# check if appkiller is already running
check=$($ADB -s "$TV" shell "ps -A -o PID,ARGS 2>/dev/null | grep '[a]ppkiller'" | tr -d '\r')
if [ -n "$check" ]; then
  exit 0
fi

# not running — push and start
log "appkiller not running, starting..."

if [ -f "$LOCAL_SCRIPT" ]; then
  $ADB -s "$TV" push "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" >/dev/null 2>&1
  log "pushed script"
fi

$ADB -s "$TV" shell "rm -rf /data/local/tmp/appkiller.lock" >/dev/null 2>&1
$ADB -s "$TV" shell "nohup sh $REMOTE_SCRIPT > /dev/null 2>&1 &" >/dev/null 2>&1

sleep 3

verify=$($ADB -s "$TV" shell "ps -A -o PID,ARGS 2>/dev/null | grep '[a]ppkiller'" | tr -d '\r')
if [ -n "$verify" ]; then
  log "OK started: $verify"
else
  log "FAIL start"
fi
