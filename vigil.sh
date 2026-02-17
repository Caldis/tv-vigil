#!/bin/sh
# vigil.sh — Manage the tv-vigil appkiller daemon on Android TV
#
# Usage:
#   ./vigil.sh [--json] <command> [args] [tv_ip]
#   ./vigil.sh status [tv_ip]       Full system state
#   ./vigil.sh log [N] [tv_ip]      Show last N log lines (default 20)
#   ./vigil.sh stats [tv_ip]        Show kill statistics
#   ./vigil.sh start [tv_ip]        Push script and start daemon
#   ./vigil.sh stop [tv_ip]         Stop the daemon
#
# Exit codes:
#   0 — success
#   1 — invalid usage / bad arguments
#   2 — cannot connect to TV (ADB unreachable)
#   3 — daemon not running (status only, informational)
#   4 — start/stop operation failed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_SCRIPT="/data/local/tmp/appkiller.sh"
REMOTE_LOG="/data/local/tmp/appkiller.log"
REMOTE_STATS="/data/local/tmp/appkiller_stats"
REMOTE_LOCK="/data/local/tmp/appkiller.lock"

# --- Detect ADB ---
if [ -n "${ADB:-}" ]; then
  : # use provided ADB
elif command -v adb >/dev/null 2>&1; then
  ADB="adb"
elif [ -x "/opt/homebrew/bin/adb" ]; then
  ADB="/opt/homebrew/bin/adb"
else
  echo "Error: adb not found." >&2
  exit 1
fi

# --- JSON helpers (defined early for use in arg parsing) ---
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr -d '\n\r'
}

# Unified JSON envelope
json_ok() { printf '{"ok":true,"error":null,"data":%s}\n' "$1"; }
json_err() { printf '{"ok":false,"error":"%s","data":%s}\n' "$(json_escape "$1")" "${2:-null}"; }

# --- Parse --json flag ---
JSON=0
if [ "$1" = "--json" ]; then
  JSON=1; shift
fi

# --- Parse command ---
CMD=""
case "$1" in
  status|log|stats|start|stop) CMD="$1"; shift ;;
esac

if [ -z "$CMD" ]; then
  if [ "$JSON" = 1 ]; then
    json_err "missing command (status|log|stats|start|stop)"
  else
    echo "Usage: vigil.sh [--json] <status|log|stats|start|stop> [tv_ip]"
  fi
  exit 1
fi

# --- Parse log line count ---
LOG_LINES=20
if [ "$CMD" = "log" ]; then
  case "$1" in
    *[!0-9]*) ;; # not purely numeric, skip
    [0-9]*) LOG_LINES="$1"; shift ;;
  esac
fi

TV_IP="${1:-192.168.1.209}"
TV_PORT="5555"
TV="${TV_IP}:${TV_PORT}"

# --- Helpers ---
adb_sh() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" shell "$@" < /dev/null 2>/dev/null
}

# Validate a value is digits-only; return 1 if not
is_numeric() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Emit a value as JSON number if numeric, otherwise null
json_num() {
  if is_numeric "$1"; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

# --- Connect ---
MSYS_NO_PATHCONV=1 "$ADB" connect "$TV" < /dev/null >/dev/null 2>&1
if ! adb_sh echo ok >/dev/null; then
  if [ "$JSON" = 1 ]; then
    json_err "cannot connect to TV" "$(printf '{"target":"%s"}' "$(json_escape "$TV")")"
  else
    echo "ERROR: Cannot reach $TV"
  fi
  exit 2
fi

# --- Daemon detection ---
get_daemon_pid() {
  _pid=$(adb_sh "ps -A -o PID,ARGS 2>/dev/null | grep '[a]ppkiller'" | awk '{print $1}' | tr -d '\r' | head -n 1)
  # Only return if it's a valid numeric PID
  is_numeric "$_pid" && printf '%s' "$_pid"
}

DAEMON_PID=$(get_daemon_pid)

# ============================================================
# Command: status
# ============================================================
if [ "$CMD" = "status" ]; then
  SCRIPT_CHECK=$(adb_sh "ls $REMOTE_SCRIPT 2>/dev/null" | tr -d '\r')
  STATS_RAW=$(adb_sh cat "$REMOTE_STATS" 2>/dev/null | tr -d '\r')

  S_PID=$(printf '%s' "$STATS_RAW" | grep "^pid=" | sed 's/pid=//')
  S_UPTIME=$(printf '%s' "$STATS_RAW" | grep "^uptime_min=" | sed 's/uptime_min=//')
  S_CYCLES=$(printf '%s' "$STATS_RAW" | grep "^total_cycles=" | sed 's/total_cycles=//')
  S_KILLS=$(printf '%s' "$STATS_RAW" | grep "^total_kills=" | sed 's/total_kills=//')
  S_SKIPS=$(printf '%s' "$STATS_RAW" | grep "^total_skips=" | sed 's/total_skips=//')

  DAEMON_STATE="stopped"
  [ -n "$DAEMON_PID" ] && DAEMON_STATE="running"
  SCRIPT_INSTALLED=false
  [ -n "$SCRIPT_CHECK" ] && SCRIPT_INSTALLED=true

  if [ "$JSON" = 1 ]; then
    _pid_json="null"
    [ -n "$DAEMON_PID" ] && _pid_json="$DAEMON_PID"
    _data=$(printf '{"connected":true,"daemon":"%s","pid":%s,"uptime_min":%s,"total_cycles":%s,"total_kills":%s,"total_skips":%s,"script_installed":%s}' \
      "$DAEMON_STATE" "$_pid_json" "$(json_num "$S_UPTIME")" "$(json_num "$S_CYCLES")" "$(json_num "$S_KILLS")" "$(json_num "$S_SKIPS")" "$SCRIPT_INSTALLED")
    if [ -z "$STATS_RAW" ] && [ -z "$DAEMON_PID" ]; then
      json_err "daemon not running" "$_data"; exit 3
    elif [ -z "$DAEMON_PID" ]; then
      json_err "daemon not running" "$_data"; exit 3
    else
      json_ok "$_data"; exit 0
    fi
  else
    echo "=== tv-vigil: Status ==="
    echo ""
    echo "Daemon:  $DAEMON_STATE"
    [ -n "$DAEMON_PID" ] && echo "PID:     $DAEMON_PID"
    [ "$SCRIPT_INSTALLED" = true ] && echo "Script:  installed" || echo "Script:  not found"
    echo ""
    if [ -n "$STATS_RAW" ]; then
      echo "Stats:"
      printf '%s\n' "$STATS_RAW" | grep -v "^#" | grep -v "^---" | sed 's/^/  /'
    else
      echo "Stats:   not available"
    fi
  fi

  [ -z "$STATS_RAW" ] && [ -z "$DAEMON_PID" ] && exit 3
  [ -z "$DAEMON_PID" ] && exit 3
  exit 0
fi

# ============================================================
# Command: log
# ============================================================
if [ "$CMD" = "log" ]; then
  LOG_RAW=$(adb_sh "tail -n $LOG_LINES $REMOTE_LOG 2>/dev/null" | tr -d '\r')

  if [ "$JSON" = 1 ]; then
    printf '{"ok":true,"error":null,"data":{"lines":['
    FIRST=1
    printf '%s\n' "$LOG_RAW" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ "$FIRST" = 1 ] && FIRST=0 || printf ','
      printf '"%s"' "$(json_escape "$line")"
    done
    printf ']}}\n'
  else
    if [ -n "$LOG_RAW" ]; then
      printf '%s\n' "$LOG_RAW"
    else
      echo "(no log entries)"
    fi
  fi
  exit 0
fi

# ============================================================
# Command: stats
# ============================================================
if [ "$CMD" = "stats" ]; then
  STATS_RAW=$(adb_sh cat "$REMOTE_STATS" 2>/dev/null | tr -d '\r')

  if [ -z "$STATS_RAW" ]; then
    if [ "$JSON" = 1 ]; then
      json_err "no stats available"
    else
      echo "(no stats available — daemon may not have run yet)"
    fi
    exit 3
  fi

  if [ "$JSON" = 1 ]; then
    S_PID=$(printf '%s' "$STATS_RAW" | grep "^pid=" | sed 's/pid=//')
    S_UPTIME=$(printf '%s' "$STATS_RAW" | grep "^uptime_min=" | sed 's/uptime_min=//')
    S_CYCLES=$(printf '%s' "$STATS_RAW" | grep "^total_cycles=" | sed 's/total_cycles=//')
    S_KILLS=$(printf '%s' "$STATS_RAW" | grep "^total_kills=" | sed 's/total_kills=//')
    S_SKIPS=$(printf '%s' "$STATS_RAW" | grep "^total_skips=" | sed 's/total_skips=//')

    printf '{"ok":true,"error":null,"data":{"pid":%s,' "$(json_num "$S_PID")"
    printf '"uptime_min":%s,' "$(json_num "$S_UPTIME")"
    printf '"total_cycles":%s,' "$(json_num "$S_CYCLES")"
    printf '"total_kills":%s,' "$(json_num "$S_KILLS")"
    printf '"total_skips":%s,' "$(json_num "$S_SKIPS")"

    # per-app kills
    printf '"per_app":{'
    FIRST=1
    printf '%s\n' "$STATS_RAW" | awk '/^---per-app/,0' | grep '=' | while IFS='=' read -r pkg cnt; do
      [ -z "$pkg" ] && continue
      [ "$FIRST" = 1 ] && FIRST=0 || printf ','
      printf '"%s":%s' "$(json_escape "$pkg")" "$(json_num "$cnt")"
    done
    printf '}}}\n'
  else
    printf '%s\n' "$STATS_RAW"
  fi
  exit 0
fi

# ============================================================
# Command: start
# ============================================================
if [ "$CMD" = "start" ]; then
  # Kill existing if running
  if [ -n "$DAEMON_PID" ]; then
    adb_sh "kill $DAEMON_PID" >/dev/null 2>&1
    sleep 1
  fi

  # Push script
  LOCAL_SCRIPT="$SCRIPT_DIR/appkiller.sh"
  if [ -f "$LOCAL_SCRIPT" ]; then
    MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" push "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" >/dev/null 2>&1
  fi

  # Clear lock and start
  adb_sh "rm -rf $REMOTE_LOCK" >/dev/null
  MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" shell "nohup sh $REMOTE_SCRIPT > /dev/null 2>&1 &" </dev/null >/dev/null 2>&1
  sleep 3

  NEW_PID=$(get_daemon_pid)
  if [ -n "$NEW_PID" ]; then
    if [ "$JSON" = 1 ]; then
      json_ok "$(printf '{"pid":%s}' "$NEW_PID")"
    else
      echo "Daemon started (PID $NEW_PID)"
    fi
    exit 0
  else
    if [ "$JSON" = 1 ]; then
      json_err "daemon failed to start"
    else
      echo "ERROR: Daemon failed to start."
    fi
    exit 4
  fi
fi

# ============================================================
# Command: stop
# ============================================================
if [ "$CMD" = "stop" ]; then
  if [ -z "$DAEMON_PID" ]; then
    if [ "$JSON" = 1 ]; then
      json_ok '{"was_running":false}'
    else
      echo "Daemon is not running."
    fi
    exit 0
  fi

  adb_sh "kill $DAEMON_PID" >/dev/null 2>&1
  adb_sh "rm -rf $REMOTE_LOCK" >/dev/null 2>&1
  sleep 1

  VERIFY=$(get_daemon_pid)
  if [ -z "$VERIFY" ]; then
    if [ "$JSON" = 1 ]; then
      json_ok "$(printf '{"was_running":true,"killed_pid":%s}' "$DAEMON_PID")"
    else
      echo "Daemon stopped (was PID $DAEMON_PID)"
    fi
    exit 0
  else
    if [ "$JSON" = 1 ]; then
      json_err "failed to stop daemon" "$(printf '{"pid":%s}' "$DAEMON_PID")"
    else
      echo "ERROR: Failed to stop daemon (PID $DAEMON_PID)"
    fi
    exit 4
  fi
fi
