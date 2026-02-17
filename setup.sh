#!/bin/sh
# tv-vigil setup script
# Deploys appkiller to TV and optionally installs watchdog crontab
# Usage: ./setup.sh [TV_IP]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TV_IP="${1:-192.168.1.209}"
TV_PORT="5555"
TV="${TV_IP}:${TV_PORT}"
REMOTE_PATH="/data/local/tmp/appkiller.sh"

# detect adb
if command -v adb >/dev/null 2>&1; then
  ADB="adb"
elif [ -x "/opt/homebrew/bin/adb" ]; then
  ADB="/opt/homebrew/bin/adb"
else
  echo "Error: adb not found. Install Android platform-tools first."
  echo "  macOS:  brew install android-platform-tools"
  echo "  Linux:  sudo apt install android-tools-adb"
  exit 1
fi

echo "==> Connecting to TV at $TV ..."
$ADB connect "$TV" 2>&1 | grep -q "connected\|already" || {
  echo "Failed to connect. Make sure:"
  echo "  1. TV is on and connected to the same network"
  echo "  2. ADB debugging is enabled (Settings > Developer Options)"
  exit 1
}

echo "==> Pushing appkiller.sh to TV ..."
$ADB -s "$TV" push "$SCRIPT_DIR/appkiller.sh" "$REMOTE_PATH"

echo "==> Starting appkiller on TV ..."
$ADB -s "$TV" shell "rm -rf /data/local/tmp/appkiller.lock" 2>/dev/null
$ADB -s "$TV" shell "nohup sh $REMOTE_PATH > /dev/null 2>&1 &"
sleep 2

check=$($ADB -s "$TV" shell "ps -A -o PID,ARGS 2>/dev/null | grep '[a]ppkiller'" | tr -d '\r')
if [ -n "$check" ]; then
  echo "==> OK! appkiller is running: $check"
else
  echo "==> Warning: appkiller may not have started. Check manually."
fi

# optional: install watchdog crontab
echo ""
printf "Install watchdog crontab (auto-restart after TV reboot)? [y/N] "
read -r answer
case "$answer" in
  [yY]*)
    # update watchdog config
    WATCHDOG="$SCRIPT_DIR/watchdog.sh"
    ADB_PATH=$(command -v adb 2>/dev/null || echo "/opt/homebrew/bin/adb")

    # add to crontab if not already present
    if crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
      echo "Watchdog already in crontab, skipping."
    else
      (crontab -l 2>/dev/null; echo "*/5 * * * * /bin/sh $WATCHDOG") | crontab -
      echo "==> Watchdog added to crontab (every 5 min)"
    fi
    ;;
  *)
    echo "Skipped. You can add it later:"
    echo "  (crontab -l; echo \"*/5 * * * * /bin/sh $SCRIPT_DIR/watchdog.sh\") | crontab -"
    ;;
esac

echo ""
echo "Done! Useful commands:"
echo "  View log:   adb -s $TV shell cat /data/local/tmp/appkiller.log"
echo "  View stats: adb -s $TV shell cat /data/local/tmp/appkiller_stats"
echo "  Stop:       adb -s $TV shell kill \$(adb -s $TV shell pidof sh)"
