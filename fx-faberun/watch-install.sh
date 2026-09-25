#!/bin/sh
# Schedule fx-faberun/watch.sh every six hours on this machine: a launchd agent on
# macOS, a crontab line on Linux. Idempotent: re-running replaces the entry.
# FX_FABERUN_NOTIFY, when set, is recorded into the schedule.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
watch="$root/fx-faberun/watch.sh"
label=run.feliperun.fx-faberun.watch
notify=${FX_FABERUN_NOTIFY:-}

case "$(uname -s)" in
  Darwin)
    plist="$HOME/Library/LaunchAgents/$label.plist"
    mkdir -p "$(dirname "$plist")" "$HOME/.local/state/fx-faberun"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$watch</string></array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATH</string>
    <key>FX_FABERUN_NOTIFY</key><string>$notify</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.local/state/fx-faberun/launchd.out</string>
  <key>StandardErrorPath</key><string>$HOME/.local/state/fx-faberun/launchd.err</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    printf '[ok] watch · launchd agent %s every 6 h (%s)\n' "$label" "$plist"
    ;;
  Linux)
    line="17 */6 * * * PATH=$PATH FX_FABERUN_NOTIFY='$notify' /bin/sh $watch # $label"
    { crontab -l 2>/dev/null | grep -v "# $label\$" || true; printf '%s\n' "$line"; } | crontab -
    printf '[ok] watch · crontab entry %s every 6 h\n' "$label"
    ;;
  *) printf '[fail] watch · no scheduler for %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
