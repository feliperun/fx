#!/bin/sh
# Rebase the flavor branch onto the official fx and report where every
# flavor patch stands. Run from anywhere inside the fork's checkout.
#
# Exit status: 0 when the flavor is current or was rebased cleanly, 2 when a
# patch conflicts with upstream (the rebase is aborted and nothing moves).
# It never pushes: the caller decides, so a local run and the scheduled
# workflow share one code path.
set -eu

upstream_url=${FX_UPSTREAM_URL:-https://github.com/vercel-labs/fx.git}
upstream_repo=${FX_UPSTREAM_REPO:-vercel-labs/fx}
root=$(git rev-parse --show-toplevel)
cd "$root"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$upstream_url"
fi
git fetch --quiet upstream main

upstream_head=$(git rev-parse upstream/main)
if [ "$(git merge-base HEAD upstream/main)" = "$upstream_head" ]; then
  echo "[ok] flavor already sits on upstream $(git rev-parse --short upstream/main)"
else
  before=$(git rev-parse HEAD)
  if ! git -c commit.gpgsign=false rebase --quiet upstream/main; then
    git rebase --abort
    echo "[fail] a flavor patch conflicts with upstream $(git rev-parse --short upstream/main); resolve it by hand" >&2
    exit 2
  fi
  echo "[ok] rebased flavor $(git rev-parse --short "$before") -> $(git rev-parse --short HEAD) onto upstream $(git rev-parse --short upstream/main)"
fi

echo "[info] upstream version: $(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/main.zig)"
echo "[info] flavor patches above upstream:"
git log --reverse --format='  %h %s' upstream/main..HEAD

if command -v gh >/dev/null 2>&1; then
  grep -v '^#' flavor/upstream-prs.txt | while read -r number subject; do
    [ -n "$number" ] || continue
    state=$(gh pr view "$number" -R "$upstream_repo" --json state --jq .state 2>/dev/null || echo unknown)
    echo "[pr] #$number $state · $subject"
  done
fi
