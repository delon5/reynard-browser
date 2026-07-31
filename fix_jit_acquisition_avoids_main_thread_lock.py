#!/usr/bin/env python3
"""
fix_jit_acquisition_avoids_main_thread_lock.py

Stops the JIT Acquisition row taking a contended file lock on the main
thread.

-------------------------------------------------------------------
THE PROBLEM
-------------------------------------------------------------------

JITSettingsSection builds the row synchronously on the main thread:

    if !JITEnabler.hasActiveJITSession() {

which reaches hasAnyDebuggedJITSessionAcrossProcesses, and that opens
the shared PID file and spins on flock for up to half a second:

    NSTimeInterval lockDeadline = now + 0.5;
    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (now > lockDeadline) { close(fd); return NO; }
        usleep(5000);
    }

Content processes take that same lock whenever they record themselves
as CS_DEBUGGED, so with several starting at once the Settings screen
can stall the UI for the full deadline. Not a freeze, but a visible
hitch - and an unnecessary one.

-------------------------------------------------------------------
THE FIX
-------------------------------------------------------------------

Check the cheap thing first.

The timestamp marker written by recordDebuggedAcquisitionTimestamp is
read WITHOUT any lock - it is a single small file, deliberately
unlocked, last-write-wins. And it alone answers what the row actually
asks: did acquisition succeed during this app session.

So the marker check moves ahead of the locked PID read. Whenever JIT is
working - the overwhelmingly common case, and the only one where the
lock is contended, since contention comes from processes recording
successful acquisition - the function returns immediately and never
opens the locked file at all.

The PID path is kept as a fallback for the case where the marker is
missing but live sessions exist. That should not happen, since any
process that records a pid also writes the marker, but it costs nothing
to keep and avoids relying on that invariant.

-------------------------------------------------------------------
WHAT DOES NOT CHANGE
-------------------------------------------------------------------

The answer. Both paths already reported the same thing; this only
changes which is consulted first. A device with JIT active still reads
"Acquired (TXM)", and one without still reads "Not Acquired".

Nor does it change the pruning behaviour - readLiveJITSessionPIDs still
drops dead pids and writes the list back when that path runs. It just
runs less often.

Run from the repo root:
    python3 fix_jit_acquisition_avoids_main_thread_lock.py

Safe to re-run: skipped if already applied.

App code only - build-app.sh alone. No Gecko rebuild.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


class EditError(Exception):
    pass


def apply_edit(relative_path, old, new, already_applied_marker):
    path = REPO_ROOT / relative_path
    if not path.exists():
        raise EditError(f"{relative_path}: file not found at {path}")

    content = path.read_text(encoding="utf-8")

    if already_applied_marker in content:
        print(f"  SKIP  {relative_path} (already applied)")
        return

    count = content.count(old)
    if count == 0:
        raise EditError(
            f"{relative_path}: expected text not found \u2014 paste the "
            f"current file and it can be rebuilt against it."
        )
    if count > 1:
        raise EditError(
            f"{relative_path}: expected text appears {count} times, "
            f"expected exactly 1 \u2014 refusing to guess which one."
        )

    path.write_text(content.replace(old, new, 1), encoding="utf-8")
    print(f"  OK    {relative_path}")


JIT_SUPPORT = "browser/Reynard/JIT/RPPairing/JITSupport.m"

OLD = '''BOOL hasAnyDebuggedJITSessionAcrossProcesses(void) {
    NSURL *fileURL = debuggedJITSessionsFileURL();
    if (!fileURL) return NO;'''

NEW = '''BOOL hasAnyDebuggedJITSessionAcrossProcesses(void) {
    // ADDED - the cheap check first. See
    // fix_jit_acquisition_avoids_main_thread_lock.py.
    //
    // This is called from JITSettingsSection on the MAIN THREAD while
    // building a cell, and the PID path below spins on flock for up to
    // half a second. Content processes take that same lock whenever
    // they record themselves as CS_DEBUGGED, so several starting at
    // once could stall the Settings screen for the full deadline.
    //
    // The marker is read without any lock - one small file,
    // deliberately unlocked, last-write-wins - and it alone answers
    // what this row asks: did acquisition succeed this session. So
    // whenever JIT is working, which is also the only time the lock
    // below is contended, this returns without opening the locked file
    // at all.
    NSTimeInterval markerTimestamp = debuggedAcquisitionTimestamp();
    if (markerTimestamp > 0 && markerTimestamp >= gReynardProcessStartTime) {
        return YES;
    }

    NSURL *fileURL = debuggedJITSessionsFileURL();
    if (!fileURL) return NO;'''

MARKER = "the cheap check first"

EDITS = [
    (JIT_SUPPORT, OLD, NEW, MARKER),
]


def main():
    print(f"Avoiding the main-thread lock in {REPO_ROOT}\n")
    errors = []
    for relative_path, old, new, marker in EDITS:
        try:
            apply_edit(relative_path, old, new, marker)
        except EditError as e:
            print(f"  FAIL  {relative_path}: {e}")
            errors.append(relative_path)

    if errors:
        print()
        print(f"{len(errors)} edit(s) failed \u2014 paste the file and it can")
        print("be rebuilt against the real text.")
        sys.exit(1)

    source = (REPO_ROOT / JIT_SUPPORT).read_text(encoding="utf-8")

    if source.count("{") != source.count("}") or source.count("(") != source.count(")"):
        print()
        print("BALANCE CHECK FAILED \u2014 review JITSupport.m by hand.")
        sys.exit(1)

    # The helpers it depends on must be defined earlier in the file.
    marker_fn = source.find("static NSTimeInterval debuggedAcquisitionTimestamp(void)")
    start_time = source.find("static NSTimeInterval gReynardProcessStartTime")
    use_site = source.find("NSTimeInterval markerTimestamp = debuggedAcquisitionTimestamp();")
    if not (0 <= marker_fn < use_site and 0 <= start_time < use_site):
        print()
        print("ORDERING CHECK FAILED \u2014 the marker helpers must be")
        print("defined before this uses them.")
        sys.exit(1)

    # The locked path must still exist as the fallback.
    if "flock(fd, LOCK_EX | LOCK_NB)" not in source:
        print()
        print("The locked fallback path is gone - it should be kept.")
        sys.exit(1)

    print()
    print("Balance, ordering and fallback checks passed.")
    print()
    print("Opening JIT settings no longer takes a contended lock on the")
    print("main thread when JIT is active - which is exactly when that")
    print("lock is busy.")
    print()
    print("The answer is unchanged; only which check runs first.")


if __name__ == "__main__":
    main()
