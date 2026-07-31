#!/usr/bin/env python3
"""
fix_cancel_only_on_real_teardown.py

Moves cancelAllDebugSessionCalls out of sceneWillResignActive, where it
was destroying every working debug session on any momentary
interruption.

-------------------------------------------------------------------
WHAT IT WAS DOING
-------------------------------------------------------------------

From the device log, sixteen healthy sessions killed at once:

    08:41:39.322  (pid 18638) starting continue command (iteration 2)
    08:41:39.322  (pid 18637) starting continue command (iteration 2)
    08:41:41.693  cancelAllDebugSessionCalls: cancelled 16 in-flight call(s)
    08:41:41.695  Debug loop ended for pid 18634: Failed to send debug command
    08:41:41.695  Debug loop ended for pid 18632: Failed to send debug command
    08:41:41.695  skipping detach - transport already dead

Those loops were fine. Continues were returning in 20-24ms and
breakpoints were being serviced normally. willResignActive fired and
the cancellation ended all sixteen.

willResignActive fires for a swipe up, Control Centre, a notification
pull - the app need not even leave the foreground. So every one of
those was destroying JIT for every content process, and with nothing
re-attaching them in that build they never came back.

-------------------------------------------------------------------
WHY THE REASONING WAS WRONG
-------------------------------------------------------------------

fix_split_cancel_from_detach.py argued that cancellation was the cheap
half and teardown the expensive half, so cancellation could safely run
at the earlier, more frequent transition.

That is wrong. debug_proxy_cancel aborts whatever call is in flight,
and for a healthy loop that call is the continue it is waiting on. The
abort surfaces as a failed command, the loop treats that as fatal and
exits, and the session is over.

Cancellation IS teardown. There was never a cheap half.

It was designed for loops blocked on a dead transport, but it cannot
tell those apart from healthy ones - a loop waiting on a continue looks
identical either way.

-------------------------------------------------------------------
THE FIX
-------------------------------------------------------------------

  sceneWillResignActive    defer new attaches only. Nothing torn down.
  sceneDidEnterBackground  detach AND cancel - genuinely going away.

The XPC hang that prompted moving it earlier is handled by
fix_defer_attaches_while_inactive.py instead, which stops new attaches
starting without touching existing sessions. That is the actually cheap
intervention this was supposed to be.

Run from the repo root:
    python3 fix_cancel_only_on_real_teardown.py

Safe to re-run: each edit is skipped individually if already applied.

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


SCENE_DELEGATE = "browser/Reynard/SceneDelegate.swift"

# --- 1: remove it from the frequent transition ---

OLD_RESIGN = '''        // Release any thread parked in a debug proxy read before
        // ExtensionFoundation starts synchronously messaging extensions
        // - a debugger-stopped extension cannot answer that, and the
        // app is killed with 0x8BADF00D waiting for a reply. This fires
        // before that cascade begins.
        //
        // Cancellation only, not the full teardown: this also fires for
        // Control Centre and notification pulls, where tearing sessions
        // down would cost a re-attach per process for a moment's
        // interruption. The deliberate teardown stays in
        // sceneDidEnterBackground. See fix_split_cancel_from_detach.py.
        //
        // Safe to do here - unlike presenting a view controller, which
        // the comment below rightly warns against, this touches no
        // UIKit state at all.
        JITEnabler.cancelAllDebugSessionCalls()'''

NEW_RESIGN = '''        // REMOVED the cancelAllDebugSessionCalls() call that used to be
        // here - see fix_cancel_only_on_real_teardown.py.
        //
        // It was described as the cheap half of teardown. It is not:
        // debug_proxy_cancel aborts whatever call is in flight, and for
        // a healthy loop that is the continue it is waiting on. The
        // abort surfaces as a failed command and the loop exits.
        //
        // On device it killed sixteen working sessions at once, at a
        // moment when every one of them was servicing breakpoints
        // normally. This transition fires for a swipe up, Control
        // Centre, or a notification pull - the app need not even leave
        // the foreground - so JIT was being destroyed for every content
        // process on any momentary interruption.
        //
        // Teardown now happens only in sceneDidEnterBackground, where
        // the app is genuinely going away. The XPC hang this was meant
        // to avoid is handled by deferring new attaches instead, which
        // touches no existing session.'''

MARKER_RESIGN = "REMOVED the cancelAllDebugSessionCalls() call"

# --- 2: put it where teardown belongs ---

OLD_BACKGROUND = '''        requestDetachForAllDebugSessions()'''

NEW_BACKGROUND = '''        requestDetachForAllDebugSessions()
        
        // Cancellation belongs here rather than at willResignActive -
        // see fix_cancel_only_on_real_teardown.py. It ends every loop
        // it touches, which is correct when the app is genuinely going
        // away and destructive when it is not.
        //
        // Paired with the detach above: the flag reaches loops between
        // iterations, and this reaches the ones blocked inside a
        // continue that would otherwise stay stuck for the whole
        // suspension.
        JITEnabler.cancelAllDebugSessionCalls()'''

MARKER_BACKGROUND = "Cancellation belongs here rather than at willResignActive"

EDITS = [
    (SCENE_DELEGATE, OLD_RESIGN, NEW_RESIGN, MARKER_RESIGN),
    (SCENE_DELEGATE, OLD_BACKGROUND, NEW_BACKGROUND, MARKER_BACKGROUND),
]


def main():
    print(f"Restricting cancellation to real teardown in {REPO_ROOT}\n")
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

    scene = (REPO_ROOT / SCENE_DELEGATE).read_text(encoding="utf-8")

    if scene.count("{") != scene.count("}") or scene.count("(") != scene.count(")"):
        print()
        print("BALANCE CHECK FAILED \u2014 review SceneDelegate.swift by hand.")
        sys.exit(1)

    # Exactly one call, and it must be in the background handler.
    calls = scene.count("JITEnabler.cancelAllDebugSessionCalls()")
    if calls != 1:
        print()
        print(f"Expected exactly one cancellation call, found {calls}.")
        sys.exit(1)

    resign_at = scene.find("func sceneWillResignActive")
    background_at = scene.find("func sceneDidEnterBackground")
    call_at = scene.find("JITEnabler.cancelAllDebugSessionCalls()")

    if resign_at < 0 or background_at < 0:
        print()
        print("Could not locate both lifecycle methods.")
        sys.exit(1)

    # It must sit inside the background handler, not the resign one.
    if not (call_at > background_at):
        print()
        print("The cancellation is not inside sceneDidEnterBackground -")
        print("check by hand.")
        sys.exit(1)

    print()
    print("Balance and placement checks passed.")
    print()
    print("willResignActive no longer tears anything down. A swipe up or")
    print("Control Centre pull leaves every debug session intact.")
    print()
    print("Teardown happens only when the app genuinely backgrounds,")
    print("where the detach and the cancellation now sit together.")


if __name__ == "__main__":
    main()
