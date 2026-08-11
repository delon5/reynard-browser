#!/bin/sh
# preflight-build.sh - refuse to package an IPA whose libxul predates the
# patch series.
#
# The failure this exists to catch: patches/ is edited, the app target is
# rebuilt, and the IPA ships an unchanged libxul - so the device runs the
# OLD engine while the tree says otherwise. It is invisible at build time
# (the app builds fine) and presents on device as a fix that "did not
# work", which costs a whole test cycle to diagnose. Four sessions lost a
# round to it before it was named.
#
# Two questions, in order:
#
#   1. Does the PREPARED tree match the patch series?
#      Answered by prepare-firefox.sh --check-prepared. A "no" means
#      patches changed and prepare has not run since.
#
#   2. Was libxul built AFTER that tree was written?
#      A prepared tree with a stale binary is the silent case - the
#      source is right, the compiled artifact is not.
#
# Note what this deliberately does NOT do: grep the source for expected
# strings. Those checks read the wrong tree (engine/firefox is the
# pristine submodule; .build/firefox is what compiles) and go stale as
# the code moves. A string that survives only in a comment - as
# "No EME session for this key request" now does - reads as a failure
# when the tree is perfectly correct.
#
# Usage: tools/development/preflight-build.sh [repo-root]
# Exit 0 = safe to package. Non-zero = rebuild Gecko first.

set -eu

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
PREPARED="$ROOT/.build/firefox"
OBJDIR="$PREPARED/obj-aarch64-apple-ios"
XUL="$OBJDIR/dist/bin/XUL"

fail() {
	echo "PREFLIGHT FAILED: $1" >&2
	echo >&2
	echo "  Run:  ./tools/development/build-gecko-quick.sh" >&2
	echo "  Then: ./tools/release/build-app.sh" >&2
	exit 1
}

[ -d "$PREPARED" ] || fail "no prepared tree at $PREPARED - Gecko has never been built here"

# 1. Prepared source vs the patch series.
if ! "$ROOT/tools/firefox/prepare-firefox.sh" --check-prepared >/dev/null 2>&1; then
	fail "the prepared tree does not match patches/ - patches changed since the last prepare"
fi

# 2. Binary vs source. Any source file newer than XUL means the compile
#    predates the current tree.
[ -f "$XUL" ] || fail "no libxul at $XUL - Gecko has never finished a build here"

NEWER="$(find "$PREPARED" -name '*.cpp' -o -name '*.h' -o -name '*.mm' -o -name '*.ipdl' -o -name '*.webidl' \
	2>/dev/null | grep -v '/obj-aarch64-apple-ios/' | while IFS= read -r f; do
		[ "$f" -nt "$XUL" ] && { echo "$f"; break; }
	done)"

if [ -n "$NEWER" ]; then
	fail "libxul is older than the prepared source (e.g. ${NEWER#"$PREPARED"/}) - the app would ship the previous engine"
fi

echo "Preflight OK: prepared tree matches patches/, and libxul is newer than it."
