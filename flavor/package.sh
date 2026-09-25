#!/bin/sh
# Build release archives of the flavor, named like the official ones
# (fx-<os>-<arch>.tar.gz plus .sha256), with the version X.Y.Z-flavor.N.
#
#   flavor/package.sh <N> [target ...]
#
# Targets default to the host. The version is stamped into src/main.zig for
# the build only and restored afterwards, so the committed source always
# carries the upstream version and never conflicts on a sync.
set -eu

build=${1:?usage: flavor/package.sh <flavor build number> [zig-target ...]}
shift
root=$(git rev-parse --show-toplevel)
cd "$root"
base=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/main.zig)
version="$base-flavor.$build"
dist="$root/zig-out/flavor-dist"
mkdir -p "$dist"

cp src/main.zig "$dist/.main.zig.orig"
trap 'cp "$dist/.main.zig.orig" src/main.zig; rm -f "$dist/.main.zig.orig"' EXIT
sed "s/^pub const version = \".*\";/pub const version = \"$version\";/" "$dist/.main.zig.orig" > src/main.zig

if [ "$#" -eq 0 ]; then
  set -- native
fi
for target in "$@"; do
  case "$target" in
    native) os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); flag="" ;;
    *) os=${target#*-}; arch=${target%%-*}; flag="-Dtarget=$target" ;;
  esac
  case "$os" in darwin) os=macos ;; esac
  case "$arch" in arm64) arch=aarch64 ;; esac
  name="fx-$os-$arch"
  prefix="$dist/$name"
  rm -rf "$prefix"
  # shellcheck disable=SC2086
  zig build -Doptimize=ReleaseSafe $flag -p "$prefix"
  cp LICENSE THIRD_PARTY_NOTICES.md "$prefix/bin/"
  # No extended attributes: a macOS tar records com.apple.provenance, which
  # GNU tar warns about on every extraction.
  COPYFILE_DISABLE=1 tar --no-xattrs -czf "$dist/$name.tar.gz" -C "$prefix/bin" fx LICENSE THIRD_PARTY_NOTICES.md
  (cd "$dist" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name.tar.gz"; else shasum -a 256 "$name.tar.gz"; fi > "$name.tar.gz.sha256")
  echo "[ok] $dist/$name.tar.gz ($version)"
done
echo "$version" > "$dist/VERSION"
