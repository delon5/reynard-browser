#!/bin/sh

set -euo pipefail

# Incremental Gecko build. See fix_add_build_gecko_quick.py for why the
# normal path always rebuilds everything.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/.build/firefox"

. "$ROOT_DIR/tools/xcode/use-xcode-26.2.sh"
. "$ROOT_DIR/tools/toolchains/release.env"

TARGET="$REYNARD_RUST_TARGET"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"
WASM_CC="${WASM_CC:-$LLVM_PREFIX/bin/clang}"
WASM_CXX="${WASM_CXX:-$LLVM_PREFIX/bin/clang++}"

if [ ! -x "$WASM_CC" ] || [ ! -x "$WASM_CXX" ]; then
	echo "Missing WebAssembly compiler under $LLVM_PREFIX."
	exit 1
fi

export WASM_CC WASM_CXX
export RUSTUP_TOOLCHAIN="$REYNARD_RUST_TOOLCHAIN"
export CC="$LLVM_PREFIX/bin/clang"
export CXX="$LLVM_PREFIX/bin/clang++"
export AR="$LLVM_PREFIX/bin/llvm-ar"
export RANLIB="$LLVM_PREFIX/bin/llvm-ranlib"
export LD="$LLVM_PREFIX/bin/ld.lld"
export PATH="$LLVM_PREFIX/bin:${PATH}"

cd "$ROOT_DIR"

# Nothing prepared yet, so there is nothing to be incremental about.
if [ ! -d "$FIREFOX_DIR" ] || ! git -C "$FIREFOX_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	echo "No prepared Firefox tree yet - use build-gecko.sh for the first build." >&2
	exit 1
fi

# --manifest runs every validation the normal prepare does - revision
# match, clean submodule, every patch applying to a temporary index - and
# prints the resulting tree without touching the prepared worktree.
MANIFEST="$("$ROOT_DIR/tools/firefox/prepare-firefox.sh" --manifest)"
EXPECTED_TREE="$(printf '%s\n' "$MANIFEST" | sed -n 's/^patched_tree=//p')"

if [ -z "$EXPECTED_TREE" ]; then
	echo "Could not determine the expected Firefox tree; falling back." >&2
	"$ROOT_DIR/tools/firefox/prepare-firefox.sh"
else
	CURRENT_TREE="$(git -C "$FIREFOX_DIR" write-tree 2>/dev/null || true)"
	if [ "$CURRENT_TREE" = "$EXPECTED_TREE" ] && git -C "$FIREFOX_DIR" diff --quiet --; then
		echo "Prepared Firefox tree $EXPECTED_TREE is already current."
	elif ! git -C "$FIREFOX_DIR" diff --quiet --; then
		# read-tree -m refuses to clobber local modifications, and it is
		# right to refuse - fall back rather than lose them.
		echo "Prepared Firefox tree has local modifications; using the full prepare."
		"$ROOT_DIR/tools/firefox/prepare-firefox.sh"
	else
		echo "Updating prepared Firefox tree to $EXPECTED_TREE (changed files only)..."
		git -C "$FIREFOX_DIR" read-tree -u -m "$EXPECTED_TREE"

		if [ "$(git -C "$FIREFOX_DIR" write-tree)" != "$EXPECTED_TREE" ]; then
			echo "Incremental update did not produce the expected tree; using the full prepare." >&2
			"$ROOT_DIR/tools/firefox/prepare-firefox.sh"
		else
			# So a later build-gecko.sh agrees the tree is current
			# instead of redoing the destructive checkout.
			MARKER="$(git -C "$FIREFOX_DIR" rev-parse --git-path reynard-prepared-manifest)"
			printf '%s\n' "$MANIFEST" > "$MARKER.tmp.$$"
			mv "$MARKER.tmp.$$" "$MARKER"
		fi
	fi
fi

rm -f "$FIREFOX_DIR/.mozconfig"

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

cd "$FIREFOX_DIR"
./mach build

GECKO_DIST="$FIREFOX_DIR/obj-aarch64-apple-ios/dist"
"$ROOT_DIR/tools/firefox/gecko-artifact-manifest.sh" write "$GECKO_DIST"
