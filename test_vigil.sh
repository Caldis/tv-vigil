#!/bin/sh
# test_vigil.sh — Smoke tests for vigil.sh --json envelope
# Mocks ADB and validates JSON output + exit codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; TOTAL=0

# --- Setup mock ADB ---
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/adb" << MOCK
#!/bin/sh
case "\$*" in
  *connect*) echo "connected to 192.168.1.209:5555" ;;
  *"shell echo ok"*) echo "ok" ;;
  *"shell ps -A -o PID,ARGS"*)
    if [ -f "$MOCK_DIR/killed" ]; then
      echo ""
    else
      echo " 5678 sh /data/local/tmp/appkiller.sh"
    fi ;;
  *"shell ls /data/local/tmp/appkiller.sh"*)
    echo "/data/local/tmp/appkiller.sh" ;;
  *"shell cat /data/local/tmp/appkiller_stats"*)
    printf 'pid=5678\nuptime_min=42\ntotal_cycles=100\ntotal_kills=15\ntotal_skips=85\n---per-app---\ncom.rogue.app=10\ncom.other.app=5\n' ;;
  *"shell tail"*)
    printf '[2024-01-01 12:00] Cycle 1\n[2024-01-01 12:01] Killed com.rogue.app\n' ;;
  *"shell kill"*) touch "$MOCK_DIR/killed" ;;
  *"shell rm"*) ;;
  *"shell nohup"*) rm -f "$MOCK_DIR/killed" ;;
  *push*) ;;
  *) echo "mock: unhandled: \$*" >&2 ;;
esac
MOCK
chmod +x "$MOCK_DIR/adb"

export ADB="$MOCK_DIR/adb"

# --- Test helpers ---
check() {
  _name="$1"; _expected_rc="$2"; shift 2
  TOTAL=$((TOTAL + 1))
  _out=$("$@" 2>/dev/null); _rc=$?
  _ok=true

  if [ "$_rc" != "$_expected_rc" ]; then
    echo "FAIL [$_name] exit code: expected=$_expected_rc got=$_rc"
    _ok=false
  fi

  if [ -z "$_out" ]; then
    echo "FAIL [$_name] empty output"
    _ok=false
  else
    if ! echo "$_out" | python -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      echo "FAIL [$_name] invalid JSON: $_out"
      _ok=false
    fi
    _has_env=$(echo "$_out" | python -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'ok' in d and 'error' in d and 'data' in d else 'no')" 2>/dev/null)
    if [ "$_has_env" != "yes" ]; then
      echo "FAIL [$_name] missing envelope (ok/error/data): $_out"
      _ok=false
    fi
  fi

  if [ "$_ok" = true ]; then
    PASS=$((PASS + 1))
    echo "PASS [$_name]"
  else
    FAIL=$((FAIL + 1))
  fi
}

# --- Tests ---
check "status"       0  sh "$SCRIPT_DIR/vigil.sh" --json status
check "log"          0  sh "$SCRIPT_DIR/vigil.sh" --json log
check "log-N"        0  sh "$SCRIPT_DIR/vigil.sh" --json log 5
check "stats"        0  sh "$SCRIPT_DIR/vigil.sh" --json stats
rm -f "$MOCK_DIR/killed"
check "stop"         0  sh "$SCRIPT_DIR/vigil.sh" --json stop
check "start"        0  sh "$SCRIPT_DIR/vigil.sh" --json start
check "no-command"   1  sh "$SCRIPT_DIR/vigil.sh" --json

# Test unreachable TV
cat > "$MOCK_DIR/adb_fail" << 'FAILMOCK'
#!/bin/sh
case "$*" in
  *connect*) echo "failed" ;;
  *"shell echo ok"*) exit 1 ;;
  *) exit 1 ;;
esac
FAILMOCK
chmod +x "$MOCK_DIR/adb_fail"
ADB="$MOCK_DIR/adb_fail" check "connect-fail" 2 sh "$SCRIPT_DIR/vigil.sh" --json status

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
