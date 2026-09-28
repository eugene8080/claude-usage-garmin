"""Sideload any Garmin project's .prg (the watch app or any face) onto the watch over USB/MTP.

    python garmin/tools/sideload.py grid                 # newest Claude Grid build
    python garmin/tools/sideload.py terminal app         # several, in order
    python garmin/tools/sideload.py path/to/Some.prg     # an explicit file (e.g. a dist/variants/ build)
    python garmin/tools/sideload.py --list               # what each name would pick, and how old it is
    python garmin/tools/sideload.py grid --dry-run       # resolve + find the watch, copy nothing

NAMES are the project folders: `watch-app` (alias `app`) and every `garmin/faces/<name>/` - a new
face is picked up automatically. For a name, the newest top-level .prg in the project's dist/ or
build/ is used, keeping only builds for PRODUCT (the Connect IQ device id in the file name, e.g.
ClaudeGrid-fenix847mm.prg; a name with no device suffix, like ClaudeUsage.prg, is assumed to be
for PRODUCT). dist/variants/ is ignored: those are separate test apps - pass their path explicitly.

The .prg's build time is always printed before copying. The previous single-face script silently
re-copied a 19 Sep 2026 build for days, so a face that "didn't change" was really an old file:
if the age looks wrong, rebuild first (monkeyc ... -r into the project's dist/).

RUN IT INTERACTIVELY - from a terminal, or from the Claude Code chat input as
    ! python D:\\dev\\claude-usage-widget\\garmin\\tools\\sideload.py grid
with the watch connected by USB and its screen AWAKE and UNLOCKED. Windows MTP writes silently do
nothing when the watch is asleep or when run from a background (non-interactive) session: the
copy "succeeds" and no file arrives. That is why every copy is confirmed by looking the file up on
the watch afterwards (installed .prg files don't show in a folder listing, so it's a name lookup) and
checking it is the NEW file: the right size, and not the same entry that was there before the copy.

It is never silent: while Windows copies (in a worker thread, because the copy call blocks until
Windows is done - including while a "Replace or Skip Files" dialog waits for an answer) it reports
progress every few seconds, names any dialog Windows has opened for it and tries to bring it to the
front, and it always ends with a summary line.
If a face doesn't change after install, remove the old copy on the watch (or restart the watch)
to clear the cached one, then reselect it. Stored settings survive a sideload (they are kept per
app id), so new defaults in properties.xml won't show over an existing install.

Needs pywin32 (Shell.Application COM) - only for the copy, not for --list.

Exit status: 0 = every file confirmed on the watch (or --list / --dry-run succeeded)
             1 = a copy failed, or was not confirmed within --timeout seconds of Windows finishing
             2 = bad arguments, no matching .prg, pywin32 missing, or the watch not found
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import threading
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

log = logging.getLogger("sideload")

HERE = Path(__file__).resolve().parent
DEFAULT_GARMIN = HERE.parent                   # garmin/
DEFAULT_DEVICE = "tactix 8 - 51mm"             # the watch's name under This PC in File Explorer
DEFAULT_PRODUCT = "fenix847mm"                 # its Connect IQ device id (fenix 8 / tactix 8 47 & 51 mm)
ALIASES = {"app": "watch-app"}
IQ_NS = "{http://www.garmin.com/xml/connectiq}"
SSF_DRIVES = 0x11                              # Shell.Application namespace id of "This PC"
# CopyHere flag: answer "Yes to All" to any prompt, so an existing copy on the watch is replaced
# instead of a "Replace or Skip Files" dialog blocking the copy (MTP ignores most other flags).
FOF_NOCONFIRMATION = 0x10
HEARTBEAT_S = 5                                # progress line interval while Windows copies


class SideloadError(Exception):
    """A setup problem the user has to fix (exit status 2)."""


# ---- choosing the file ----------------------------------------------------------------------

def projects(garmin: Path) -> dict[str, Path]:
    """Project name -> folder: the watch app plus every face that has a manifest."""
    found: dict[str, Path] = {}
    if (garmin / "watch-app" / "manifest.xml").is_file():
        found["watch-app"] = garmin / "watch-app"
    for manifest in sorted((garmin / "faces").glob("*/manifest.xml")):
        found[manifest.parent.name] = manifest.parent
    return found


def manifest_products(project: Path) -> set[str]:
    """The Connect IQ device ids a project targets (used to recognise device suffixes in names)."""
    try:
        root = ET.parse(project / "manifest.xml").getroot()
    except (OSError, ET.ParseError) as ex:
        raise SideloadError("cannot read %s: %s" % (project / "manifest.xml", ex)) from ex
    return {p.get("id", "") for p in root.iter(IQ_NS + "product")} - {""}


@dataclass(frozen=True)
class Candidate:
    path: Path
    built: datetime
    product_in_name: bool   # False = the file name carries no device id (assumed to match)


def candidates(project: Path, product: str) -> list[Candidate]:
    """Top-level .prg files in dist/ and build/ built for `product`, newest first."""
    known = manifest_products(project)
    out: list[Candidate] = []
    for sub in ("dist", "build"):
        folder = project / sub
        if not folder.is_dir():
            continue
        for prg in folder.glob("*.prg"):            # top level only: dist/variants/ is skipped
            suffix = prg.stem.rsplit("-", 1)[-1] if "-" in prg.stem else ""
            if suffix in known and suffix != product:
                continue                              # a build for another device
            out.append(Candidate(prg, datetime.fromtimestamp(prg.stat().st_mtime), suffix == product))
    return sorted(out, key=lambda c: c.built, reverse=True)


def age(t: datetime) -> str:
    secs = max(0, int((datetime.now() - t).total_seconds()))
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return "%d%s ago" % (secs // n, unit)
    return "just now"


def resolve(targets: list[str], garmin: Path, product: str) -> list[Candidate]:
    """Turn each target (project name or .prg path) into the file to copy."""
    known = projects(garmin)
    chosen: list[Candidate] = []
    for target in targets:
        as_path = Path(target)
        if as_path.suffix.lower() == ".prg":
            if not as_path.is_file():
                raise SideloadError("no such file: %s" % as_path)
            chosen.append(Candidate(as_path.resolve(), datetime.fromtimestamp(as_path.stat().st_mtime), True))
            continue
        name = ALIASES.get(target, target)
        if name not in known:
            raise SideloadError("unknown project %r - choose from: %s (or give a .prg path)"
                                % (target, ", ".join(sorted(known) + sorted(ALIASES))))
        found = candidates(known[name], product)
        if not found:
            raise SideloadError("no %s build for %s in %s or %s - build it first, e.g.\n"
                                "    monkeyc -f %s -o %s -y <developer_key.der> -d %s -r"
                                % (name, product, known[name] / "dist", known[name] / "build",
                                   known[name] / "monkey.jungle",
                                   known[name] / "dist" / ("<Name>-%s.prg" % product), product))
        chosen.append(found[0])
    names = [c.path.name.lower() for c in chosen]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        # Same name = same destination on the watch: the second copy would replace the first.
        raise SideloadError("two targets resolve to the same file name %s" % sorted(dupes))
    return chosen


def print_list(garmin: Path, product: str) -> None:
    for name, folder in projects(garmin).items():
        found = candidates(folder, product)
        label = name + (" (app)" if name == "watch-app" else "")
        if not found:
            log.info("%-18s no %s build in dist/ or build/", label, product)
            continue
        for i, c in enumerate(found):
            log.info("%-18s %s %-40s built %s (%s)%s", label if i == 0 else "", "->" if i == 0 else "  ",
                     c.path.relative_to(folder).as_posix(), c.built.strftime("%Y-%m-%d %H:%M"),
                     age(c.built), "" if c.product_in_name else "  [no device in name]")


# ---- the watch (Windows Shell / MTP) -----------------------------------------------------------

def shell_app() -> Any:
    try:
        import win32com.client  # noqa: PLC0415 - optional dependency, only needed to copy
    except ImportError as ex:
        raise SideloadError("pywin32 is required for the copy: python -m pip install pywin32") from ex
    return win32com.client.Dispatch("Shell.Application")


def child(folder: Any, *names: str) -> Any:
    """The first item in a Shell folder whose name is one of `names` (MTP names vary by case)."""
    items = folder.Items()
    have = {items.Item(i).Name: items.Item(i) for i in range(items.Count)}
    for n in names:
        if n in have:
            return have[n]
    return None


def apps_folder(shell: Any, device: str) -> Any:
    """The watch's GARMIN/Apps Shell folder, or raise with what was found instead."""
    this_pc = shell.Namespace(SSF_DRIVES)
    watch = child(this_pc, device)
    if watch is None:
        items = this_pc.Items()
        # A watch is an MTP device and never gets a drive letter, so drives ("Data (D:)") and
        # mapped shares are left out of the hint - what remains is what --device could name.
        seen = sorted(n for n in (items.Item(i).Name for i in range(items.Count))
                      if not re.search(r"\([A-Z]:\)$", n))
        raise SideloadError("watch %r not found under This PC - connect it by USB, wake and unlock it. "
                            "Other devices without a drive letter: %s. Use --device to pick another."
                            % (device, ", ".join(seen) or "none"))
    storage = child(watch.GetFolder, "Internal Storage", "Primary")
    garmin = child(storage.GetFolder, "GARMIN", "Garmin") if storage is not None else None
    apps = child(garmin.GetFolder, "Apps", "APPS") if garmin is not None else None
    if apps is None:
        raise SideloadError("%r is connected but has no Internal Storage/GARMIN/Apps folder visible - "
                            "unlock the watch and allow USB file access" % device)
    return apps.GetFolder


def watch_entry(shell: Any, device: str, name: str) -> tuple[int, str] | None:
    """(size in bytes, modified date) of GARMIN/Apps/<name> on the watch, or None if absent."""
    item = apps_folder(shell, device).ParseName(name)
    if item is None:
        return None
    return int(item.Size), str(item.ModifyDate)


def own_dialogs() -> list[tuple[int, str]]:
    """Visible top-level windows of THIS process: the dialogs Windows' copy engine opens for the
    CopyHere call (progress, "Replace or Skip Files", errors) belong to the calling process."""
    try:
        import win32gui  # noqa: PLC0415
        import win32process  # noqa: PLC0415
    except ImportError:
        return []
    pid = os.getpid()
    found: list[tuple[int, str]] = []

    def visit(hwnd: int, _: Any) -> bool:
        if win32gui.IsWindowVisible(hwnd) and win32process.GetWindowThreadProcessId(hwnd)[1] == pid:
            title = win32gui.GetWindowText(hwnd)
            if title:
                found.append((hwnd, title))
        return True

    try:
        win32gui.EnumWindows(visit, None)
    except Exception:  # noqa: BLE001 - window enumeration is best-effort diagnostics
        return []
    return found


def surface(hwnd: int) -> None:
    """Best effort: bring a copy dialog in front of the terminal so it gets answered."""
    try:
        import win32gui  # noqa: PLC0415
        win32gui.SetForegroundWindow(hwnd)
    except Exception:  # noqa: BLE001 - Windows may refuse; the dialog is still named in the log
        pass


def _copy_worker(device: str, prg: Path, outcome: dict[str, Any]) -> None:
    """Runs the blocking CopyHere in its own COM apartment (a Shell object can't cross threads)."""
    try:
        import pythoncom  # noqa: PLC0415
        pythoncom.CoInitialize()
        try:
            shell = shell_app()
            src = shell.Namespace(str(prg.parent)).ParseName(prg.name)
            if src is None:
                raise SideloadError("Windows Shell cannot see %s" % prg)
            apps_folder(shell, device).CopyHere(src, FOF_NOCONFIRMATION)
        finally:
            pythoncom.CoUninitialize()
    except BaseException as ex:  # noqa: BLE001 - handed back to the main thread
        outcome["error"] = ex


def copy_and_confirm(shell: Any, device: str, prg: Path, timeout: int) -> bool:
    """Copy one .prg into GARMIN/Apps, reporting progress, and confirm the new file arrived."""
    size = prg.stat().st_size
    before = watch_entry(shell, device, prg.name)
    if before is not None:
        log.info("  the watch already has a %s (%d bytes, %s) - replacing it", prg.name, *before)

    outcome: dict[str, Any] = {}
    worker = threading.Thread(target=_copy_worker, args=(device, prg, outcome), daemon=True)
    started = time.monotonic()
    worker.start()
    surfaced: set[int] = set()
    while True:
        worker.join(HEARTBEAT_S)
        if not worker.is_alive():
            break
        dialogs = own_dialogs()
        titles = ", ".join('"%s"' % t for _, t in dialogs)
        log.info("  Windows is still copying (%ds)%s", time.monotonic() - started,
                 (" - open dialog: %s. If it asks a question, answer it." % titles) if dialogs else "")
        for hwnd, _ in dialogs:
            if hwnd not in surfaced:
                surface(hwnd)
                surfaced.add(hwnd)
    if "error" in outcome:
        err = outcome["error"]
        if isinstance(err, SideloadError):
            raise err
        log.error("  the copy failed: %s", err)
        return False
    log.info("  Windows finished in %ds; checking the watch has the new file ...", time.monotonic() - started)

    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            now = watch_entry(shell, device, prg.name)
        except SideloadError:
            now = None              # the device can drop off briefly while it takes the file
        last = now
        if now is not None and now[0] == size:
            if before is None or now != before:
                return True
            if before[0] == size:
                # Same size and date as the copy that was already there: Windows kept the date, so
                # this is the same build (or one byte-for-byte the same size) - nothing to tell apart.
                log.info("  the watch shows the same size and date as before - this build was already on it")
                return True
        time.sleep(1)
    log.error("  last seen on the watch: %s", "nothing" if last is None else "%d bytes, %s" % last)
    return False


# ---- entry point ------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="*", help="project names (watch-app/app, grid, terminal, ...) or .prg paths")
    ap.add_argument("--list", action="store_true", help="show the builds each name would pick, then exit")
    ap.add_argument("--dry-run", action="store_true", help="resolve files and find the watch, copy nothing")
    ap.add_argument("--device", default=DEFAULT_DEVICE, help="watch name under This PC (default %(default)r)")
    ap.add_argument("--product", default=DEFAULT_PRODUCT, help="Connect IQ device id (default %(default)s)")
    ap.add_argument("--timeout", type=int, default=60, help="seconds to wait for each file to appear (default 60)")
    ap.add_argument("--garmin", type=Path, default=DEFAULT_GARMIN, help="the garmin/ folder (default: this checkout's)")
    args = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # device names can be non-ASCII
    except (AttributeError, ValueError):
        pass
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)

    try:
        if args.list:
            print_list(args.garmin, args.product)
            return 0
        if not args.targets:
            ap.error("name at least one project or .prg (see --list)")
        chosen = resolve(args.targets, args.garmin, args.product)
        for c in chosen:
            log.info("%s  built %s (%s)%s", c.path, c.built.strftime("%Y-%m-%d %H:%M"), age(c.built),
                     "" if c.product_in_name else "  [no device in name - assuming %s]" % args.product)
        shell = shell_app()
        apps_folder(shell, args.device)            # fail before copying anything if the watch is absent
        log.info("watch: %s / Internal Storage / GARMIN / Apps - found", args.device)
        if args.dry_run:
            log.info("dry run: nothing copied")
            return 0
        failed = []
        log.info("(Ctrl+C aborts)")
        for n, c in enumerate(chosen, 1):
            log.info("[%d/%d] copying %s (%d bytes) ...", n, len(chosen), c.path.name, c.path.stat().st_size)
            if copy_and_confirm(shell, args.device, c.path, args.timeout):
                log.info("  OK: %s is on the watch.", c.path.name)
            else:
                failed.append(c.path)
                log.error("  NOT CONFIRMED. Wake and unlock the watch and re-run, or drag %s onto the "
                          "watch's GARMIN\\Apps folder in File Explorer.", c.path)
        if failed:
            log.error("Done: %d of %d copied; NOT confirmed: %s", len(chosen) - len(failed), len(chosen),
                      ", ".join(f.name for f in failed))
            return 1
        log.info("Done: all %d on the watch. It installs them now - disconnect once it has finished.",
                 len(chosen))
        return 0
    except KeyboardInterrupt:
        log.error("Aborted. A copy Windows had already started may still finish on its own.")
        return 1
    except SideloadError as ex:
        log.error("ERROR: %s", ex)
        return 2


if __name__ == "__main__":
    sys.exit(main())
