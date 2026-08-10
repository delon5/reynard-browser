#!/usr/bin/env python3
"""
ips_backtrace.py -- extract thread backtraces from Apple .ips crash and
watchdog reports (the JSON format used since iOS 15 / macOS 12).

Usage:
    python3 ips_backtrace.py Report.ips               summary + hung thread + digest of the rest
    python3 ips_backtrace.py Report.ips --all         full backtraces for every thread
    python3 ips_backtrace.py Report.ips --thread 28   full backtrace for one thread
    python3 ips_backtrace.py Report.ips --images      binary image table (UUIDs, for atos/dSYM)
"""
import argparse
import json
import sys

# Topmost frames that just mean "parked waiting" -- skipped when picking the
# one-line description of a non-faulting thread.
WAIT_SYMBOLS = {
    "mach_msg2_trap", "mach_msg2_internal", "mach_msg_overwrite", "mach_msg",
    "__workq_kernreturn", "__psynch_cvwait", "__psynch_mutexwait",
    "__ulock_wait", "__ulock_wait2", "kevent", "kevent64", "__select",
    "poll", "__semwait_signal", "semaphore_wait_trap",
    "semaphore_timedwait_trap", "__sigsuspend", "start_wqthread",
    "_pthread_wqthread", "_pthread_start", "thread_start",
    "_dispatch_workloop_worker_thread", "_dispatch_sema4_wait",
    "_dispatch_semaphore_wait_slow", "pthread_cond_wait",
}
WAIT_IMAGES = {"libsystem_kernel.dylib", "libsystem_pthread.dylib"}


def load_ips(path):
    """An .ips is one JSON header line followed by a JSON body."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    newline = text.find("\n")
    if newline < 0:
        sys.exit(f"{path}: not an .ips file (no header line)")
    try:
        header = json.loads(text[:newline])
        body = json.loads(text[newline + 1:])
    except json.JSONDecodeError as e:
        sys.exit(f"{path}: JSON parse failed ({e}); legacy text-format "
                 f"reports are not supported")
    return header, body


def image_name(img):
    name = img.get("name")
    if name:
        return name
    return img.get("path", "?").rsplit("/", 1)[-1] or "?"


def frame_lines(images, frames):
    out = []
    for n, fr in enumerate(frames):
        try:
            img = images[fr["imageIndex"]]
        except (KeyError, IndexError):
            img = {}
        name = image_name(img)
        offset = fr.get("imageOffset", 0)
        addr = img.get("base", 0) + offset
        symbol = fr.get("symbol")
        if symbol is not None:
            where = f"{symbol} + {fr.get('symbolLocation', 0)}"
        else:
            # Unsymbolicated: keep the address and offset so atos can
            # resolve it later against the matching dSYM/binary.
            where = f"<unsymbolicated>  ({name} + 0x{offset:x})"
        source = ""
        if fr.get("sourceFile"):
            source = f"  ({fr['sourceFile']}:{fr.get('sourceLine', '?')})"
        out.append(f"  {n:3d}  {name:<36s} 0x{addr:016x}  {where}{source}")
    return out


def thread_heading(index, thread):
    parts = [f"Thread {index}"]
    if thread.get("name"):
        parts.append(f'name "{thread["name"]}"')
    if thread.get("queue"):
        parts.append(f'queue "{thread["queue"]}"')
    if thread.get("triggered"):
        parts.append("<<< TRIGGERED (faulting / hung) >>>")
    return "  |  ".join(parts)


def digest_frame(images, thread):
    """First frame that is not generic wait plumbing -- what the thread is
    actually doing, for the one-line thread digest."""
    for fr in thread.get("frames", []):
        try:
            img = images[fr["imageIndex"]]
        except (KeyError, IndexError):
            continue
        name = image_name(img)
        symbol = fr.get("symbol")
        if name in WAIT_IMAGES or symbol in WAIT_SYMBOLS:
            continue
        if symbol is None:
            return f"{name} + 0x{fr.get('imageOffset', 0):x} (unsymbolicated)"
        return f"{name}!{symbol}"
    return "(idle / wait plumbing only)"


def print_summary(header, body):
    osv = body.get("osVersion", {})
    beta = "  [Beta]" if osv.get("releaseType") == "Beta" else ""
    print("== Report summary ==")
    print(f"  process    : {body.get('procName')}  pid {body.get('pid')}  "
          f"({header.get('app_version')} / {header.get('build_version')})")
    print(f"  device/OS  : {body.get('modelCode')}  {osv.get('train')} "
          f"({osv.get('build')}){beta}")
    print(f"  launched   : {body.get('procLaunch')}")
    print(f"  captured   : {body.get('captureTime')}")
    exc = body.get("exception", {})
    if exc:
        print(f"  exception  : {exc.get('type')}  signal={exc.get('signal')}")
    term = body.get("termination", {})
    if term:
        code = term.get("code")
        code_str = f"  code={code:#x}" if isinstance(code, int) else ""
        print(f"  terminated : namespace={term.get('namespace')}{code_str}")
        for reason in term.get("reasons", []):
            print(f"      {reason}")
    legacy = body.get("legacyInfo", {}).get("threadTriggered")
    if legacy:
        extra = "  ".join(f'{k} "{v}"' for k, v in legacy.items())
        print(f"  triggered  : {extra}")
    print()


def main():
    ap = argparse.ArgumentParser(
        description="Extract backtraces from an Apple .ips report")
    ap.add_argument("report", help="path to the .ips file")
    ap.add_argument("--all", action="store_true",
                    help="full backtraces for every thread")
    ap.add_argument("--thread", type=int,
                    help="full backtrace for one thread index")
    ap.add_argument("--images", action="store_true",
                    help="print the binary image table")
    args = ap.parse_args()

    header, body = load_ips(args.report)
    images = body.get("usedImages", [])
    threads = body.get("threads", [])

    print_summary(header, body)

    if args.images:
        print("== Binary images ==")
        for img in images:
            print(f"  0x{img.get('base', 0):016x}  {img.get('uuid', '?')}  "
                  f"{img.get('path', image_name(img))}")
        return

    if args.thread is not None:
        if not 0 <= args.thread < len(threads):
            sys.exit(f"thread index out of range (0..{len(threads) - 1})")
        chosen = [(args.thread, threads[args.thread])]
    elif args.all:
        chosen = list(enumerate(threads))
    else:
        fault = body.get("faultingThread", 0)
        chosen = [(i, t) for i, t in enumerate(threads)
                  if t.get("triggered") or i == fault]

    for i, t in chosen:
        print(thread_heading(i, t))
        print("\n".join(frame_lines(images, t.get("frames", []))))
        print()

    if not (args.all or args.thread is not None):
        print(f"== Other threads ({len(threads) - len(chosen)}) ==")
        shown = {i for i, _ in chosen}
        for i, t in enumerate(threads):
            if i in shown:
                continue
            label = t.get("name") or t.get("queue") or ""
            print(f"  T{i:<3d} [{label[:42]:<42s}] {digest_frame(images, t)}")


if __name__ == "__main__":
    main()
