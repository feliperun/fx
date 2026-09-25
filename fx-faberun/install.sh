#!/bin/sh
# Install fx-faberun: the official fx plus the patches on
# https://github.com/feliperun/fx/tree/fx-faberun.
#
#   curl -fsSL https://github.com/feliperun/fx/releases/latest/download/install.sh | sh
#
# Environment:
#   FX_INSTALL_DIR       where `fx` goes (default: ~/.local/bin)
#   FX_FABERUN_VERSION    a release tag such as v0.0.11-faberun.1 (default: latest)
#   FX_FABERUN_ARCHIVE    install this local fx-<os>-<arch>.tar.gz instead of downloading;
#                        its .sha256 must sit beside it
#
# Idempotent: installing the version already present only re-verifies it.
set -eu

repo=feliperun/fx
install_dir=${FX_INSTALL_DIR:-$HOME/.local/bin}

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) printf '[fail] fx · no fx-faberun build for %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) printf '[fail] fx · no fx-faberun build for %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
asset="fx-$os-$arch.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -n "${FX_FABERUN_ARCHIVE:-}" ]; then
  cp "$FX_FABERUN_ARCHIVE" "$work/$asset"
  cp "$FX_FABERUN_ARCHIVE.sha256" "$work/$asset.sha256"
else
  if [ -n "${FX_FABERUN_VERSION:-}" ]; then
    base="https://github.com/$repo/releases/download/$FX_FABERUN_VERSION"
  else
    base="https://github.com/$repo/releases/latest/download"
  fi
  curl -fsSL "$base/$asset" -o "$work/$asset"
  curl -fsSL "$base/$asset.sha256" -o "$work/$asset.sha256"
fi

expected=$(awk '{print $1}' "$work/$asset.sha256")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work/$asset" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$work/$asset" | awk '{print $1}')
fi
if [ "$expected" != "$actual" ]; then
  printf '[fail] fx · checksum mismatch for %s\n' "$asset" >&2
  exit 1
fi

tar -xzf "$work/$asset" -C "$work" fx
version=$("$work/fx" --version 2>/dev/null | head -1)
case "$version" in
  *-faberun.*) ;;
  *) printf '[fail] fx · %s is not an fx-faberun build (%s)\n' "$asset" "$version" >&2; exit 1 ;;
esac

mkdir -p "$install_dir"
if [ -x "$install_dir/fx" ] && [ "$("$install_dir/fx" --version 2>/dev/null | head -1)" = "$version" ]; then
  printf '[ok] fx · %s already installed at %s/fx\n' "$version" "$install_dir"
  exit 0
fi
# Replace atomically: a running fx keeps its inode, the next launch gets fx-faberun.
cp "$work/fx" "$install_dir/.fx.new"
chmod 755 "$install_dir/.fx.new"
mv -f "$install_dir/.fx.new" "$install_dir/fx"
printf '[ok] fx · %s installed at %s/fx\n' "$version" "$install_dir"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) printf '[warn] fx · %s is not on PATH\n' "$install_dir" ;;
esac
