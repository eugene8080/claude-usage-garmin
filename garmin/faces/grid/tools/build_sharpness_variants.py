"""Build the Claude Grid test faces for on-wrist comparison.

Each is a separate Connect IQ app (own app id + name), so they install next to the normal
"Claude Grid" and are flipped between in the watch face picker. Kept after the 25 Sep 2026 review
(A, B, D-H were retired - their findings live on in C and I):

    0  "Grid 0 Base"  neither fix - the baseline (= master), for simulator comparison
    C  "Grid C Both"  font-atlas fix + all later fixes, with the plain FONT time
    I  "Grid I Taper" C + glowing bitmap time + full-face VFD mesh overlay + tapered seconds
                      ticks (3 px outer -> 2 px inner)

I stages source-glow/ + resources-glow-vfd/ (bitmap time, from tools/build_glow_digits.py),
the shared mesh tile (garmin/shared/resources-mesh/) and resources-ticks-taper/
(tools/build_tick_font.py), and rewrites the jungle's excludeAnnotations to pick the glow/mesh
implementations.

Every stage is self-contained: the garmin/shared/ folders the jungle names (the mesh, the
per-family launcher icons) are copied into dist/variants/<tag>/shared/ and the jungle's
../../shared/ paths are repointed at the copies, because ../../ from inside dist/variants/<tag>/
would not reach garmin/shared/.

"current" = this working tree; "baseline" = the same files at git ref BASE_REF (default d376685,
the last commit before the sharpness work - master itself now carries all the fixes).
0 takes both from the baseline:
    fonts  -> resources/fonts/cg_*.fnt + cg_*_0.png   (garmin/shared/tools/genfont.py, build_fonts_grid.py)
    source -> source/*.mc
Baseline refs from before the 2026-09-27 move to garmin/faces/grid/ still have the face under
watchface-grid/; the overlay finds it at either path.

Outputs  dist/variants/ClaudeGrid-<tag>-<device>.prg  (dist/ is gitignored).

Usage (from anywhere):
    python garmin/faces/grid/tools/build_sharpness_variants.py [--base master] [--device fenix847mm]
                                                               [--only 0,C,I] [--debug]
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("variants")

HERE = Path(__file__).resolve().parent
GRID = HERE.parent                       # garmin/faces/grid/
SHARED = GRID.parents[1] / "shared"      # garmin/shared/
REPO = GRID.parents[2]                   # repo root (git works from here; ls-tree paths are root-relative)
DIST = GRID / "dist" / "variants"
SDK_ROOT = Path(os.environ.get("APPDATA", "")) / "Garmin" / "ConnectIQ" / "Sdks"
DEV_KEY = Path.home() / ".garmin-keys" / "developer_key.der"

# The face's path inside the repo now, and before the 2026-09-27 move to garmin/ - a baseline
# ref older than the move (e.g. the default d376685) only has the legacy one.
GRID_IN_REPO = GRID.relative_to(REPO).as_posix()          # "garmin/faces/grid"
LEGACY_GRID_IN_REPO = "watchface-grid"

# How the jungle refers to garmin/shared/ (relative to the face's own folder).
SHARED_PREFIX = "../../shared/"

# Everything the compiler reads from the face's own folder. editor/, tools/, build/, dist/ are
# deliberately not staged; garmin/shared/ folders are staged separately (stage_shared).
STAGE_ITEMS = ["manifest.xml", "monkey.jungle", "source", "resources"]

# Real app id in manifest.xml - replaced per variant so the variants never overwrite each other
# (or the installed Claude Grid) on the watch.
BASE_APP_ID = "484bb3405cb84a94953d3284a6c58b61"


@dataclass(frozen=True)
class Variant:
    tag: str
    name: str          # watch face picker name (AppName string)
    app_id: str        # fixed, so re-sideloading a variant replaces the same app
    fonts_fixed: bool  # use this tree's font atlases (True) or BASE_REF's (False)
    pixels_fixed: bool # use this tree's source (True) or BASE_REF's (False)
    glow_res: str | None = None  # resources-glow* folder for the bitmap time, None = font time
    mesh: bool = False           # full-face VFD mesh overlay (shared resources-mesh/ + drawMeshOverlay)
    ticks: str | None = None     # folder whose fonts/cg_ticks.* replace the default 2 px dial ticks


VARIANTS = [
    Variant("0", "Grid 0 Base", "10c6c231e3f7470a828b84bcba6ff5cd", False, False),
    Variant("C", "Grid C Both", "2bcbb3a839584517a250dde9705eafa3", True,  True),
    Variant("I", "Grid I Taper", "d861a8cf223444a9b90712ef10b4d133", True, True,
            "resources-glow-vfd", True, "resources-ticks-taper"),
]


def git(*args: str) -> bytes:
    """Run git at the repo root and return stdout bytes (raises with stderr on failure)."""
    res = subprocess.run(["git", *args], cwd=REPO, capture_output=True)
    if res.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), res.stderr.decode(errors="replace")))
    return res.stdout


def overlay_from_ref(ref: str, sub_dir: str, dest: Path, pattern: re.Pattern[str]) -> int:
    """Replace every file under the face's `sub_dir` matching `pattern` in `dest` with its content at `ref`.

    `sub_dir` is relative to the face folder (e.g. "resources/fonts"); the face is looked up at
    its current repo path first and at its pre-move path (watchface-grid/) second, so baseline
    refs from either side of the 2026-09-27 reorganisation work.

    Files are enumerated from the ref (git ls-tree), not the working tree, so a file that exists
    only in the baseline is still restored, and files added since the baseline are removed - the
    staged directory then matches the baseline exactly for that pattern.
    """
    wanted: list[str] = []
    prefix = ""
    for prefix in (GRID_IN_REPO, LEGACY_GRID_IN_REPO):
        listing = git("ls-tree", "-r", "--name-only", ref, "--", "%s/%s" % (prefix, sub_dir))
        wanted = [p for p in listing.decode().splitlines() if pattern.search(p)]
        if wanted:
            break
    if not wanted:
        raise RuntimeError("no files matching %s under %s at %s (looked in %s/ and %s/)"
                           % (pattern.pattern, sub_dir, ref, GRID_IN_REPO, LEGACY_GRID_IN_REPO))
    # Drop working-tree files of the same kind first (handles files added after the baseline).
    # `rel` is face-relative ("resources/fonts/x.fnt"); the patterns are unanchored on the left,
    # so they match it and the repo paths above alike.
    for existing in dest.rglob("*"):
        rel = existing.relative_to(dest.parent).as_posix()
        if existing.is_file() and pattern.search(rel):
            existing.unlink()
    for path in wanted:
        target = dest.parent / Path(path).relative_to(prefix)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git("show", "%s:%s" % (ref, path)))
    return len(wanted)


def stage_shared(root: Path, jungle: str) -> str:
    """Copy each garmin/shared/ folder the jungle names into root/shared/ and repoint the jungle.

    The jungle addresses shared folders as ../../shared/<name>, which only resolves from the face's
    real folder (garmin/faces/grid/). The stage lives in dist/variants/<tag>/, so the folders are
    copied beside it and the prefix rewritten to shared/ - the stage then compiles on its own and
    a later change to garmin/shared/ cannot alter an already-staged variant. Returns the new text.
    """
    names = sorted(set(re.findall(re.escape(SHARED_PREFIX) + r"([A-Za-z0-9_.-]+)", jungle)))
    for name in names:
        src = SHARED / name
        if not src.is_dir():
            raise FileNotFoundError("%s missing (named in monkey.jungle)" % src)
        shutil.copytree(src, root / "shared" / name)
    return jungle.replace(SHARED_PREFIX, "shared/")


def find_sdk() -> Path:
    if not SDK_ROOT.is_dir():
        raise FileNotFoundError("Connect IQ SDK folder not found: %s" % SDK_ROOT)
    sdks = sorted(p for p in SDK_ROOT.iterdir() if p.is_dir() and (p / "bin" / "monkeyc.bat").exists())
    if not sdks:
        raise FileNotFoundError("no SDK with bin/monkeyc.bat under %s" % SDK_ROOT)
    return sdks[-1]  # newest by name (names embed the version + date)


def stage(v: Variant, base_ref: str) -> Path:
    """Copy the compile inputs into dist/variants/<tag>/ and apply the variant's baseline overlays."""
    root = DIST / v.tag
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    for item in STAGE_ITEMS:
        src = GRID / item
        if src.is_dir():
            shutil.copytree(src, root / item)
        elif src.is_file():
            shutil.copy2(src, root / item)
        else:
            raise FileNotFoundError(src)

    if not v.fonts_fixed:
        n = overlay_from_ref(base_ref, "resources/fonts", root / "resources",
                             # fonts.xml too: it declares which atlases exist (e.g. cg_ticks is
                             # newer than master), so it must match the baseline atlases.
                             re.compile(r"resources/fonts/(cg_[^/]+\.(fnt|png)|fonts\.xml)$"))
        log.info("  [%s] fonts <- %s (%d files)", v.tag, base_ref, n)
    if not v.pixels_fixed:
        n = overlay_from_ref(base_ref, "source", root / "source",
                             re.compile(r"source/[^/]+\.mc$"))
        log.info("  [%s] source <- %s (%d files)", v.tag, base_ref, n)

    # The jungle is rewritten for EVERY test face: since 2026-09-25 the default build is the VFD
    # face, so a plain font-time face (C, 0) must switch the glow/mesh off explicitly too.
    if True:
        if (v.glow_res or v.mesh) and not v.pixels_fixed:
            raise RuntimeError("%s: glow digits / mesh need the current source" % v.tag)
        # Each feature is an (annotation pair, extra folders) switch; the jungle is rewritten so
        # the chosen implementation of drawGlowTime / drawMeshOverlay is the one compiled in.
        # WeatherNow (garmin/shared/source-weather) is part of every build; stage_shared() copies it.
        src_paths, res_paths = ["source", SHARED_PREFIX + "source-weather"], ["resources"]
        exclude = ["font_time" if v.glow_res else "glow_time",
                   "plain_overlay" if v.mesh else "mesh_overlay"]
        folders: list[str] = []
        if v.glow_res:
            src_paths.append("source-glow")
            res_paths.append(v.glow_res)
            folders += ["source-glow", v.glow_res]
        if v.mesh:
            # The mesh tile is shared with Claude Terminal; stage_shared() copies it in below.
            res_paths.append(SHARED_PREFIX + "resources-mesh")
        for folder in folders:
            if not (GRID / folder).is_dir():
                raise FileNotFoundError("%s missing - run tools/build_glow_digits.py" % (GRID / folder))
            shutil.copytree(GRID / folder, root / folder)
        jungle = root / "monkey.jungle"
        j = jungle.read_text(encoding="utf-8")
        j, n1 = re.subn(r"(?m)^base\.sourcePath = .*$", "base.sourcePath = " + ";".join(src_paths), j)
        j, n2 = re.subn(r"(?m)^base\.resourcePath = .*$", "base.resourcePath = " + ";".join(res_paths), j)
        j, n3 = re.subn(r"(?m)^base\.excludeAnnotations = .*$",
                        "base.excludeAnnotations = " + ";".join(exclude), j)
        if (n1, n2, n3) != (1, 1, 1):
            raise RuntimeError("monkey.jungle layout changed - could not retarget it for %s" % v.tag)
        # After the rewrite, so the mesh folder named above is staged along with the icons.
        j = stage_shared(root, j)
        jungle.write_text(j, encoding="utf-8")
        log.info("  [%s] time=%s mesh=%s", v.tag, v.glow_res or "font", "full-face" if v.mesh else "off")

    if v.ticks:
        # Swap the seconds-dial tick font (same id, same cell) for this variant's geometry.
        for name in ("cg_ticks.fnt", "cg_ticks_0.png"):
            src = GRID / v.ticks / "fonts" / name
            if not src.is_file():
                raise FileNotFoundError("%s missing - run tools/build_tick_font.py --out %s/fonts" % (src, v.ticks))
            shutil.copy2(src, root / "resources" / "fonts" / name)
        log.info("  [%s] seconds ticks from %s", v.tag, v.ticks)

    manifest = root / "manifest.xml"
    text = manifest.read_text(encoding="utf-8")
    if BASE_APP_ID not in text:
        raise RuntimeError("base app id not found in manifest - refusing to build a colliding app")
    manifest.write_text(text.replace(BASE_APP_ID, v.app_id), encoding="utf-8")

    strings = root / "resources" / "strings" / "strings.xml"
    s = strings.read_text(encoding="utf-8")
    s2, n = re.subn(r'(<string id="AppName">)[^<]*(</string>)', r"\g<1>%s\g<2>" % v.name, s)
    if n != 1:
        raise RuntimeError("AppName string not found exactly once in %s" % strings)
    strings.write_text(s2, encoding="utf-8")
    return root


def build(v: Variant, root: Path, sdk: Path, device: str, release: bool) -> Path:
    out = DIST / ("ClaudeGrid-%s-%s.prg" % (v.tag, device))
    cmd = [str(sdk / "bin" / "monkeyc.bat"), "-f", str(root / "monkey.jungle"), "-o", str(out),
           "-y", str(DEV_KEY), "-d", device, "-w"]
    if release:
        cmd.append("-r")
    res = subprocess.run(cmd, capture_output=True, text=True, shell=False)
    tail = (res.stdout + res.stderr).strip().splitlines()[-6:]
    if res.returncode != 0 or not out.exists():
        raise RuntimeError("monkeyc failed for %s:\n%s" % (v.tag, "\n".join(tail)))
    log.info("  [%s] built %s (%d bytes)", v.tag, out.name, out.stat().st_size)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    # Baseline = the face as it was before the sharpness work (the last commit before the
    # exp/grid-sharpness merge), i.e. the build that was on the watch on 2026-09-25.
    ap.add_argument("--base", default="d376685", help="git ref for the unfixed baseline (default d376685)")
    ap.add_argument("--device", default="fenix847mm", help="CIQ device id (fenix847mm = tactix 8 47/51mm)")
    ap.add_argument("--only", default="0,C,I", help="comma-separated variant tags to build")
    ap.add_argument("--debug", action="store_true", help="debug build instead of release (-r)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    if not DEV_KEY.exists():
        log.error("developer key missing: %s", DEV_KEY)
        return 2
    git("rev-parse", "--verify", args.base)  # fail fast on a bad ref
    sdk = find_sdk()
    tags = {t.strip() for t in args.only.split(",") if t.strip()}
    chosen = [v for v in VARIANTS if v.tag in tags]
    if not chosen:
        log.error("no variants selected from %s", args.only)
        return 2

    log.info("SDK %s | baseline %s | device %s", sdk.name, args.base, args.device)
    DIST.mkdir(parents=True, exist_ok=True)
    for v in chosen:
        log.info("%s  %-12s fonts=%s pixels=%s", v.tag, v.name,
                 "fixed" if v.fonts_fixed else "base", "fixed" if v.pixels_fixed else "base")
        build(v, stage(v, args.base), sdk, args.device, release=not args.debug)
    return 0


if __name__ == "__main__":
    sys.exit(main())
