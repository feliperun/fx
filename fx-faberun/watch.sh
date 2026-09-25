#!/bin/sh
# One pass of the fx-faberun watcher, for a scheduler on an operator's machine
# (see watch-install.sh) or a hand run. It does what the fx-faberun workflow does,
# without GitHub Actions: rebase onto upstream, build, run the tests that
# cover the fx-faberun patches, push a moved branch, and report upstream pull
# requests. It notifies only on change: a conflict, a pull request whose state
# moved, or a new upstream version (a new fx-faberun release to cut).
#
# Environment:
#   FX_FABERUN_REMOTE   the fork's remote in this checkout (default: fork)
#   FX_FABERUN_NOTIFY   a command that receives one event on stdin as `<kind>|<detail>`,
#                      kind being conflict, tests, upstream or prs (default: none)
#   FX_FABERUN_STATE    state directory (default: ~/.local/state/fx-faberun)
set -eu

remote=${FX_FABERUN_REMOTE:-fork}
state=${FX_FABERUN_STATE:-$HOME/.local/state/fx-faberun}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p "$state"
log="$state/watch.log"
report="$state/last-report.txt"

notify() {
  printf '%s\n' "$1" >> "$log"
  if [ -n "${FX_FABERUN_NOTIFY:-}" ]; then
    printf '%s\n' "$1" | sh -c "$FX_FABERUN_NOTIFY" || true
  fi
}

printf '== %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
git switch --quiet fx-faberun
git fetch --quiet "$remote" fx-faberun
git merge --quiet --ff-only "$remote/fx-faberun" 2>/dev/null || true
before=$(git rev-parse HEAD)

set +e
fx-faberun/sync.sh > "$report" 2>&1
status=$?
set -e
cat "$report" >> "$log"
if [ "$status" -eq 2 ]; then
  notify "conflict|$(grep '\[fail\]' "$report")"
  exit 2
fi

if [ "$(git rev-parse HEAD)" != "$before" ]; then
  zig build
  printf 'test {\n    _ = @import("core/skills/skill_runtime.zig");\n    _ = @import("gateway/chat_completions_protocol.zig");\n}\n' > src/zz_fx_faberun_watch_test.zig
  set +e
  zig test src/zz_fx_faberun_watch_test.zig --test-filter "loadVisibleSkills" >> "$log" 2>&1 &&
    zig test src/zz_fx_faberun_watch_test.zig --test-filter "chat completions" >> "$log" 2>&1
  tests=$?
  set -e
  rm -f src/zz_fx_faberun_watch_test.zig
  if [ "$tests" -ne 0 ]; then
    git reset --quiet --hard "$before"
    notify "tests|the rebased fx-faberun fails its patch tests; see $log"
    exit 1
  fi
  git push --quiet --force-with-lease "$remote" HEAD:fx-faberun
  printf '[ok] pushed fx-faberun %s\n' "$(git rev-parse --short HEAD)" >> "$log"
fi

version=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/main.zig)
if [ "$(cat "$state/upstream-version" 2>/dev/null)" != "$version" ]; then
  [ -f "$state/upstream-version" ] && notify "upstream|$version"
  printf '%s\n' "$version" > "$state/upstream-version"
fi

grep '^\[pr\]' "$report" | sort > "$state/prs.new" || true
if [ -f "$state/prs" ] && ! cmp -s "$state/prs" "$state/prs.new"; then
  notify "prs|$(tr '\n' ' ' < "$state/prs.new")"
fi
mv "$state/prs.new" "$state/prs"
