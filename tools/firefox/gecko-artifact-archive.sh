#!/bin/sh

set -eu

# Packs a completed Gecko build (the obj-aarch64-apple-ios/dist tree,
# including the reynard-source-manifest.txt and
# reynard-gecko-artifact-manifest.txt files gecko-artifact-manifest.sh
# already writes alongside the binaries) into one portable archive, and
# restores it back later — including onto a checkout where .build/
# doesn't exist at all, e.g. after a clean clone or a wipe.
#
# Deliberately does not duplicate gecko-artifact-manifest.sh's
# validation logic: because that script's manifests live inside
# $GECKO_DIST itself, an archive of the whole directory is already
# self-validating — build-gecko.sh's existing `check` step, unchanged,
# is what actually decides whether a restored artifact is trustworthy.
# This script only ever handles getting the bytes there and back safely.

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <pack|restore> <archive.tar.gz>" >&2
	exit 2
fi

MODE="$1"
ARCHIVE="$2"
case "$MODE" in
	pack|restore) ;;
	*)
		echo "Usage: $0 <pack|restore> <archive.tar.gz>" >&2
		exit 2
		;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/.build/firefox"
GECKO_DIST_REL="engine/firefox/obj-aarch64-apple-ios/dist"
GECKO_DIST="$FIREFOX_DIR/obj-aarch64-apple-ios/dist"
DEFAULT_THEME_REL="engine/firefox/toolkit/mozapps/extensions/default-theme"
DEFAULT_THEME="$FIREFOX_DIR/toolkit/mozapps/extensions/default-theme"

pack() {
	if [ ! -f "$GECKO_DIST/bin/XUL" ]; then
		echo "Gecko artifact error: no completed build to pack under $GECKO_DIST" >&2
		exit 1
	fi
	if [ ! -f "$GECKO_DIST/reynard-gecko-artifact-manifest.txt" ]; then
		echo "Gecko artifact error: gecko-artifact-manifest.sh has not written a manifest yet" >&2
		exit 1
	fi

	mkdir -p "$(dirname -- "$ARCHIVE")"

	tar_args="engine/firefox/obj-aarch64-apple-ios/dist"
	if [ -d "$DEFAULT_THEME" ]; then
		tar_args="$tar_args engine/firefox/toolkit/mozapps/extensions/default-theme"
	fi

	# Gecko's dist/include tree contains absolute symlinks into the
	# object tree; -h dereferences them so the archive is portable and
	# safe to restore onto a different machine or a fresh checkout.
	# shellcheck disable=SC2086
	tar -czhf "$ARCHIVE" -C "$FIREFOX_DIR/.." $tar_args

	[ -s "$ARCHIVE" ] || {
		echo "Gecko artifact error: archive was not created: $ARCHIVE" >&2
		exit 1
	}
	echo "Packed Gecko artifact: $ARCHIVE"
}

restore() {
	if [ ! -f "$ARCHIVE" ]; then
		echo "Gecko artifact error: no archive to restore at $ARCHIVE" >&2
		exit 1
	fi

	stage="$(mktemp -d "$ROOT_DIR/.gecko-artifact-stage.XXXXXX")"
	trap 'rm -rf "$stage"' EXIT HUP INT TERM

	python3 - "$ARCHIVE" "$stage" <<'PY'
from pathlib import PurePosixPath
import sys
import tarfile

archive_path, destination = sys.argv[1:]
allowed = (
    PurePosixPath("engine/firefox/obj-aarch64-apple-ios/dist"),
    PurePosixPath("engine/firefox/toolkit/mozapps/extensions/default-theme"),
)

def is_allowed(path: PurePosixPath) -> bool:
    return any(path == prefix or prefix in path.parents for prefix in allowed)

with tarfile.open(archive_path, "r:gz") as archive:
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not is_allowed(path):
            raise SystemExit(f"unsafe or unexpected archive member: {member.name}")
    archive.extractall(destination, filter="data")
PY

	if [ ! -f "$stage/$GECKO_DIST_REL/bin/XUL" ]; then
		echo "Gecko artifact error: archive did not contain a usable build" >&2
		exit 1
	fi

	rm -rf "$GECKO_DIST" "$DEFAULT_THEME"
	mkdir -p "$(dirname -- "$GECKO_DIST")" "$(dirname -- "$DEFAULT_THEME")"
	mv "$stage/$GECKO_DIST_REL" "$GECKO_DIST"
	if [ -d "$stage/$DEFAULT_THEME_REL" ]; then
		mv "$stage/$DEFAULT_THEME_REL" "$DEFAULT_THEME"
	fi

	rm -rf "$stage"
	trap - EXIT HUP INT TERM
	echo "Restored Gecko artifact from: $ARCHIVE"
}

case "$MODE" in
	pack) pack ;;
	restore) restore ;;
esac
