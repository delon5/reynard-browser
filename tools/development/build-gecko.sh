#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/.build/firefox"

REBUILD=false
case "${1:-}" in
"") ;;
--rebuild) REBUILD=true ;;
*)
	echo "Usage: $0 [--rebuild]" >&2
	exit 2
	;;
esac

. "$ROOT_DIR/tools/xcode/use-xcode-26.2.sh"
. "$ROOT_DIR/tools/toolchains/release.env"

TARGET="$REYNARD_RUST_TARGET"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"
WASM_CC="${WASM_CC:-$LLVM_PREFIX/bin/clang}"
WASM_CXX="${WASM_CXX:-$LLVM_PREFIX/bin/clang++}"

if [ ! -x "$WASM_CC" ] || [ ! -x "$WASM_CXX" ]; then
	echo "Missing WebAssembly compiler under $LLVM_PREFIX."
	echo "Install Homebrew LLVM or set WASM_CC and WASM_CXX explicitly."
	exit 1
fi

export WASM_CC WASM_CXX
export RUSTUP_TOOLCHAIN="$REYNARD_RUST_TOOLCHAIN"

# Homebrew LLVM toolchain for building Gecko/Rust, scoped to this
# script's own process (and its children, like ./mach build) only.
# Deliberately NOT exported globally via shell profiles: Xcode's own
# app builds pick up CC/CXX/AR/LD/RANLIB from the environment too, and
# a global LD=ld.lld in particular breaks ordinary Xcode archiving —
# Apple's linker driver passes flags (-isysroot, -fapplication-extension,
# -dead_strip, etc.) that ld.lld doesn't understand at all.
export CC="$LLVM_PREFIX/bin/clang"
export CXX="$LLVM_PREFIX/bin/clang++"
export AR="$LLVM_PREFIX/bin/llvm-ar"
export RANLIB="$LLVM_PREFIX/bin/llvm-ranlib"
export LD="$LLVM_PREFIX/bin/ld.lld"
export PATH="$LLVM_PREFIX/bin:${PATH}"

cd "$ROOT_DIR"

"$ROOT_DIR/tools/firefox/prepare-firefox.sh"

mv "$FIREFOX_DIR/.mozconfig" "$FIREFOX_DIR/.mozconfig.bak"

{
echo "ac_add_options --enable-application=mobile/ios"
echo "ac_add_options --target=$TARGET"
echo "ac_add_options --enable-ios-target=$REYNARD_DEPLOYMENT_TARGET"
echo "ac_add_options --enable-webrtc"
echo "ac_add_options --enable-optimize"
echo "ac_add_options --disable-debug"
echo "ac_add_options --disable-tests"
} > "$FIREFOX_DIR/.mozconfig"

"$ROOT_DIR/tools/toolchains/validate-release-toolchain.sh" >/dev/null

GECKO_DIST="$FIREFOX_DIR/obj-aarch64-apple-ios/dist"
GECKO_ARCHIVE="$ROOT_DIR/.gecko-artifact-cache/gecko-dist.tar.gz"

# If there's no build here at all (e.g. a fresh checkout, or .build/
# was wiped), try restoring a previously-packed artifact before
# falling back to a full rebuild. This is purely an optimization
# attempt: if there's no archive, or it fails to restore, or the
# restored artifact turns out to be stale for the current
# source/patches/toolchain, the existing check step right below this
# handles that exactly as it always has, and the script proceeds to a
# normal rebuild unchanged.
if [ "$REBUILD" = false ] && [ ! -f "$GECKO_DIST/bin/XUL" ] && [ -f "$GECKO_ARCHIVE" ]; then
	echo "No existing Gecko build found; attempting to restore cached artifact..."
	"$ROOT_DIR/tools/firefox/gecko-artifact-archive.sh" restore "$GECKO_ARCHIVE" || \
		echo "Cached Gecko artifact could not be restored; will build from source."
fi

if [ "$REBUILD" = false ] &&
	REYNARD_PREPARED_VERIFIED=1 "$ROOT_DIR/tools/firefox/gecko-artifact-manifest.sh" check "$GECKO_DIST" >/dev/null 2>&1; then
	echo "Reusing Gecko artifacts for fingerprint $("$ROOT_DIR/tools/release/build-fingerprint.sh" gecko)."
	exit 0
fi

cd "$FIREFOX_DIR"
if [ "$REBUILD" = true ]; then
	./mach clobber
fi
./mach build

"$ROOT_DIR/tools/firefox/gecko-artifact-manifest.sh" write "$GECKO_DIST"

# Save a portable copy of this successful build so a future wiped or
# fresh .build/ directory doesn't require a full rebuild. Deliberately
# non-fatal: the build itself already succeeded, so a packing failure
# (e.g. low disk space) should only be a warning, not a build failure.
"$ROOT_DIR/tools/firefox/gecko-artifact-archive.sh" pack "$GECKO_ARCHIVE" || \
	echo "Warning: could not cache Gecko artifact for future builds." >&2

rm "$FIREFOX_DIR/.mozconfig"
mv "$FIREFOX_DIR/.mozconfig.bak" "$FIREFOX_DIR/.mozconfig"
