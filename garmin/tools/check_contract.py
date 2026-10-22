#!/usr/bin/env python3
"""Verify the phone <-> watch apps <-> face contract (garmin/CONTRACT.md) across every codebase.

The Android app, the two Connect IQ watch apps (Claude Usage and Codex + Cursor) and the watch
faces are compiled separately, so nothing checks that they agree on the values they exchange - the
app ids the phone sends to, the message keys and how they group, the complication ids, and the
complication label text the faces match on. A mismatch builds cleanly and fails silently on the
watch. This script reads each side's SOURCE (no build needed) plus the tables in CONTRACT.md, and
fails when any two disagree - so the document cannot drift from the code either.

Standard library only, so CI runs it with the runner's stock Python (no pip install).

Usage:   python garmin/tools/check_contract.py            (from anywhere)
Exit:    0 = every check passed
         1 = at least one mismatch (each is listed; on GitHub Actions also as an error annotation)
         2 = a source file is missing, or no longer has the shape this script parses - the parser
             needs updating alongside whatever changed
"""
from __future__ import annotations

import logging
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("contract")

REPO = Path(__file__).resolve().parents[2]
GARMIN = REPO / "garmin"
CONTRACT_MD = GARMIN / "CONTRACT.md"
WATCH_BRIDGE = REPO / "app" / "src" / "main" / "java" / "com" / "usage" / "claudewidget" / "watch" / "WatchBridge.kt"
# Shared by both watch apps (garmin/shared/source-usage/): the message keys and their groups.
SNAPSHOT_MC = GARMIN / "shared" / "source-usage" / "Snapshot.mc"
FACES_DIR = GARMIN / "faces"

# Connect IQ manifests put every element in this namespace (xmlns:iq=...), so ElementTree sees
# tags as "{uri}application" rather than "iq:application".
IQ_NS = "{http://www.garmin.com/xml/connectiq}"

# Connect IQ lets one app publish at most this many complications; monkeyc refuses more
# ("Exceeds maximum of 4 complications"). Checked here too, so the reason is on record.
MAX_COMPLICATIONS = 4

# Every face recognises a Claude meter by this substring of its longLabel.
CLAUDE_MARKER = "Claude"


@dataclass(frozen=True)
class AppSpec:
    """One watch app the phone pushes to, and what each of its complications is.

    `rows` maps every Publisher.mc ID_ constant to the Claude Terminal row it must land on
    (ClaudeFaceView.slotFor: "5H" / "1W" / "model"), or None for a meter that is NOT a Claude
    meter - whose label must then not contain CLAUDE_MARKER, or the faces would take it for one.
    A new complication id must be added here, which forces the decision.
    """
    folder: str        # under garmin/
    phone_const: str   # the WatchBridge.kt constant that holds its app id
    rows: dict[str, str | None]

    @property
    def root(self) -> Path:
        return GARMIN / self.folder


APPS: tuple[AppSpec, ...] = (
    AppSpec("watch-app", "WATCH_APP_ID",
            {"ID_FIVE": "5H", "ID_WEEK": "1W", "ID_MODEL": "model", "ID_CURSOR_API": None}),
    AppSpec("feed-app", "FEED_APP_ID",
            {"ID_CODEX_FIVE": None, "ID_CODEX_WEEK": None, "ID_CURSOR_PLAN": None, "ID_CURSOR_AUTO": None}),
)
MAIN_APP = APPS[0]

# Literal label matches each face's source must still contain. If a face changes how it matches,
# this fails - update terminal_row() below and CONTRACT.md ("How a face finds the Claude meters")
# in the same commit. Keys are folder names under garmin/faces/.
FACE_LABEL_LITERALS: dict[str, dict[str, list[str]]] = {
    "grid": {"source/ClaudeGridView.mc": ['find("Claude")']},
    "terminal": {"source/ClaudeFaceView.mc": ['find("Claude")', 'find("5-hour")',
                                              'find("weekly")', 'find("model")']},
}


class SourceShapeError(Exception):
    """A source file is missing or no longer matches what this script parses (exit status 2)."""


@dataclass
class Report:
    """Collects check outcomes; a failure never stops the run, so one pass lists every problem."""
    passed: int = 0
    failures: list[tuple[str, Path]] = field(default_factory=list)

    def check(self, ok: bool, what: str, detail: str, where: Path) -> None:
        if ok:
            self.passed += 1
            log.info("ok    %s", what)
        else:
            self.failures.append(("%s: %s" % (what, detail), where))
            log.error("FAIL  %s\n      %s\n      (%s)", what, detail, rel(where))


def rel(path: Path) -> str:
    try:
        return path.relative_to(REPO).as_posix()
    except ValueError:
        return str(path)


def read(path: Path) -> str:
    if not path.is_file():
        raise SourceShapeError("missing file: %s" % rel(path))
    return path.read_text(encoding="utf-8")


def search(pattern: str, text: str, path: Path, what: str, flags: int = 0) -> re.Match[str]:
    m = re.search(pattern, text, flags)
    if m is None:
        raise SourceShapeError("%s: could not find %s (pattern %r)" % (rel(path), what, pattern))
    return m


def parse_xml(path: Path) -> ET.Element:
    try:
        return ET.fromstring(read(path))
    except ET.ParseError as ex:
        raise SourceShapeError("%s: not well-formed XML (%s)" % (rel(path), ex)) from ex


# ---- the phone ------------------------------------------------------------------------------

@dataclass(frozen=True)
class Phone:
    app_ids: dict[str, str]                 # WatchBridge.kt constant name -> app id
    groups: tuple[frozenset[str], ...]      # one per `payload += mapOf(...)` literal, in order
    stray_keys: frozenset[str]              # keys put in the payload outside a group literal (must be none)


# A group literal: `payload += mapOf(` ... `)` with the closing paren on its own line, so the
# values' own calls - `toSafeInt()` - do not end the match early.
GROUP_LITERAL = r"payload\s*\+=\s*mapOf\((.*?)\n\s*\)"
# `"key" to value` inside a map literal; group 1 = the key.
ENTRY = r'"(\w+)"\s+to\b'
# A lone `payload["k"] = value`; group 1 = the key.
ASSIGN = r'payload\["(\w+)"\]\s*='


def parse_phone() -> Phone:
    kt = read(WATCH_BRIDGE)
    app_ids = {}
    for app in APPS:
        app_ids[app.phone_const] = search(r'%s\s*=\s*"([0-9a-fA-F]{32})"' % app.phone_const, kt, WATCH_BRIDGE,
                                          app.phone_const).group(1).lower()
    body = search(r"fun payloadOf\(.*?\{(.*?)\n\s*return payload", kt, WATCH_BRIDGE,
                  "payloadOf() ... return payload", re.S).group(1)
    groups = tuple(frozenset(re.findall(ENTRY, m.group(1))) for m in re.finditer(GROUP_LITERAL, body, re.S))
    if not groups or not all(groups):
        raise SourceShapeError("%s: payloadOf() has no `payload += mapOf(\"key\" to ...)` groups" % rel(WATCH_BRIDGE))
    outside = re.sub(GROUP_LITERAL, "", body, flags=re.S)
    stray = frozenset(re.findall(ASSIGN, outside)) | frozenset(re.findall(ENTRY, outside))
    return Phone(app_ids, groups, stray)


# ---- the watch apps -------------------------------------------------------------------------

@dataclass(frozen=True)
class Snapshot:
    keys: dict[str, str]                    # Snapshot.mc K_ constant name -> key
    groups: dict[str, frozenset[str]]       # G_ constant name -> its keys
    listed: frozenset[str]                  # the G_ names in GROUPS (the ones store() handles)


def parse_snapshot() -> Snapshot:
    mc = read(SNAPSHOT_MC)
    keys = dict(re.findall(r'const\s+(K_\w+)\s*=\s*"(\w+)"\s*;', mc))
    if not keys:
        raise SourceShapeError("%s: no `const K_... = \"key\";` constants" % rel(SNAPSHOT_MC))
    groups: dict[str, frozenset[str]] = {}
    for name, members in re.findall(r"const\s+(G_\w+)\s*=\s*\[(.*?)\]\s*;", mc, re.S):
        names = [n.strip() for n in members.split(",") if n.strip()]
        unknown = [n for n in names if n not in keys]
        if unknown:
            raise SourceShapeError("%s: %s lists %s, which are not K_ constants" % (rel(SNAPSHOT_MC), name, unknown))
        groups[name] = frozenset(keys[n] for n in names)
    listed = search(r"const\s+GROUPS\s*=\s*\[(.*?)\]\s*;", mc, SNAPSHOT_MC, "const GROUPS = [...]", re.S).group(1)
    if not groups:
        raise SourceShapeError("%s: no `const G_... = [...]` groups" % rel(SNAPSHOT_MC))
    return Snapshot(keys, groups, frozenset(n.strip() for n in listed.split(",") if n.strip()))


@dataclass(frozen=True)
class WatchApp:
    spec: AppSpec
    app_id: str
    products: frozenset[str]
    permissions: frozenset[str]
    publisher_ids: dict[str, int]           # Publisher.mc constant name -> complication id
    complication_labels: dict[int, str]     # complications.xml id -> resolved longLabel text


def manifest_facts(path: Path) -> tuple[str, frozenset[str], frozenset[str]]:
    """(app id, product ids, permission ids) of a Connect IQ manifest."""
    root = parse_xml(path)
    app = root.find(IQ_NS + "application")
    if app is None or not app.get("id"):
        raise SourceShapeError("%s: no <iq:application id=...>" % rel(path))
    products = frozenset(p.get("id", "") for p in app.iter(IQ_NS + "product"))
    perms = frozenset(p.get("id", "") for p in app.iter(IQ_NS + "uses-permission"))
    return app.get("id", "").lower(), products, perms


def parse_watch_app(spec: AppSpec) -> WatchApp:
    app_id, products, perms = manifest_facts(spec.root / "manifest.xml")
    publisher_mc = spec.root / "source" / "Publisher.mc"
    publisher = {name: int(v) for name, v in re.findall(r"const\s+(ID_\w+)\s*=\s*(\d+)\s*;", read(publisher_mc))}
    if not publisher:
        raise SourceShapeError("%s: no `const ID_... = N;` constants" % rel(publisher_mc))

    strings_xml = spec.root / "resources" / "strings" / "strings.xml"
    complications_xml = spec.root / "resources" / "complications.xml"
    strings = {s.get("id"): (s.text or "") for s in parse_xml(strings_xml).iter("string")}
    labels: dict[int, str] = {}
    for comp in parse_xml(complications_xml).iter("complication"):
        raw_id, long_label = comp.get("id"), comp.get("longLabel")
        if raw_id is None or not raw_id.isdigit() or long_label is None:
            raise SourceShapeError("%s: a <complication> lacks a numeric id or a longLabel" % rel(complications_xml))
        if long_label.startswith("@Strings."):
            ref = long_label[len("@Strings."):]
            if ref not in strings:
                raise SourceShapeError("%s: longLabel %s has no <string id=%r> in %s"
                                       % (rel(complications_xml), long_label, ref, rel(strings_xml)))
            long_label = strings[ref]
        labels[int(raw_id)] = long_label
    return WatchApp(spec, app_id, products, perms, publisher, labels)


def terminal_row(long_label: str) -> str | None:
    """Python twin of ClaudeFaceView.findAndSubscribe + slotFor: only a label containing "Claude"
    is considered at all, then its words pick the row (Monkey C String.find is case-sensitive)."""
    if CLAUDE_MARKER not in long_label:
        return None
    if "5-hour" in long_label:
        return "5H"
    if "weekly" in long_label and "model" not in long_label:
        return "1W"
    if "model" in long_label:
        return "model"
    return None


# ---- CONTRACT.md tables ---------------------------------------------------------------------

def doc_table(md: str, name: str) -> list[list[str]]:
    """Body rows (header and separator dropped) of the table between the check:<name> markers."""
    m = search(r"<!-- check:%s -->\s*\n(.*?)<!-- /check -->" % re.escape(name), md, CONTRACT_MD,
               "the <!-- check:%s --> table" % name, re.S)
    rows = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
            continue  # the |---|---| separator
        rows.append(cells)
    if len(rows) < 2:
        raise SourceShapeError("%s: the check:%s table has no body rows" % (rel(CONTRACT_MD), name))
    return rows[1:]


def code(cell: str) -> str | None:
    """The text of a cell that is exactly one `code span`, else None."""
    m = re.fullmatch(r"`([^`]+)`", cell)
    return m.group(1) if m else None


def group_label(const_name: str) -> str:
    """CONTRACT.md's name for a Snapshot.mc group: G_CLAUDE -> claude."""
    return const_name[len("G_"):].lower()


# ---- the checks -----------------------------------------------------------------------------

def run() -> Report:
    r = Report()
    phone, snap = parse_phone(), parse_snapshot()
    apps = [parse_watch_app(spec) for spec in APPS]
    md = read(CONTRACT_MD)

    # 1a. The app ids the phone sends to.
    for app in apps:
        manifest = app.spec.root / "manifest.xml"
        got = phone.app_ids[app.spec.phone_const]
        r.check(got == app.app_id, "phone %s == %s manifest id" % (app.spec.phone_const, app.spec.folder),
                "WatchBridge.kt has %s, %s has %s" % (got, rel(manifest), app.app_id), WATCH_BRIDGE)
    r.check(len({a.app_id for a in apps}) == len(apps), "every watch app has its own app id",
            "ids: %s" % [a.app_id for a in apps], WATCH_BRIDGE)
    doc_ids = set(re.findall(r"`([0-9a-fA-F]{32})`", "\n".join("|".join(row) for row in doc_table(md, "app-id"))))
    r.check(doc_ids == {a.app_id for a in apps}, "CONTRACT.md app ids are current",
            "document lists %s, code has %s" % (sorted(doc_ids), sorted(a.app_id for a in apps)), CONTRACT_MD)

    # 1b. Message keys and their groups. A group travels whole or not at all, so the phone's
    # group literals and the watch's G_ arrays must be the same partition of the same keys.
    watch_groups = set(snap.groups.values())
    phone_groups = set(phone.groups)
    r.check(phone_groups == watch_groups, "phone payload groups == Snapshot.mc groups",
            "phone only: %s; watch only: %s" % (sorted(map(sorted, phone_groups - watch_groups)),
                                                sorted(map(sorted, watch_groups - phone_groups))), WATCH_BRIDGE)
    r.check(len(phone.groups) == len(phone_groups), "the phone sends each group once",
            "payloadOf() has %d group literals for %d distinct groups" % (len(phone.groups), len(phone_groups)),
            WATCH_BRIDGE)
    r.check(not phone.stray_keys, "every payload key is inside a group literal",
            "outside any `payload += mapOf(...)`: %s - a lone key would half-set its group"
            % sorted(phone.stray_keys), WATCH_BRIDGE)
    all_keys = set(snap.keys.values())
    in_groups = [k for g in snap.groups.values() for k in g]
    r.check(sorted(in_groups) == sorted(all_keys), "every Snapshot.mc key is in exactly one group",
            "keys in no group: %s; keys in two: %s" % (sorted(all_keys - set(in_groups)),
                                                       sorted({k for k in in_groups if in_groups.count(k) > 1})),
            SNAPSHOT_MC)
    r.check(snap.listed == set(snap.groups), "Snapshot.mc GROUPS lists every group",
            "GROUPS: %s; defined: %s - store() only handles the listed ones" % (sorted(snap.listed), sorted(snap.groups)),
            SNAPSHOT_MC)
    doc_rows = {code(row[0]): row for row in doc_table(md, "payload")}
    r.check(set(doc_rows) == all_keys, "CONTRACT.md payload table lists exactly the keys",
            "document only: %s; code only: %s" % (sorted(set(doc_rows) - all_keys - {None}),
                                                   sorted(all_keys - set(doc_rows))), CONTRACT_MD)
    group_of = {k: group_label(name) for name, keys in snap.groups.items() for k in keys}
    wrong = {k: (code(row[2]) if len(row) > 2 else None, group_of.get(k))
             for k, row in doc_rows.items() if k in group_of
             and (len(row) <= 2 or code(row[2]) != group_of[k])}
    r.check(not wrong, "CONTRACT.md 'Group' column matches Snapshot.mc",
            "key: (document, code) %s" % wrong, CONTRACT_MD)

    # 2. Complications, per app.
    doc_comps: dict[tuple[str, str], list[str]] = {}
    for row in doc_table(md, "complications"):
        if len(row) < 5 or code(row[0]) is None or code(row[1]) is None:
            raise SourceShapeError("%s: complications table rows need `app` | `id` | longLabel | shortLabel | row"
                                   % rel(CONTRACT_MD))
        doc_comps[(code(row[0]) or "", code(row[1]) or "")] = row
    for app in apps:
        publisher_mc = app.spec.root / "source" / "Publisher.mc"
        strings_xml = app.spec.root / "resources" / "strings" / "strings.xml"
        xml_ids, pub_ids = set(app.complication_labels), set(app.publisher_ids.values())
        r.check(xml_ids == pub_ids, "%s: complications.xml ids == Publisher.mc ids" % app.spec.folder,
                "xml: %s; Publisher: %s" % (sorted(xml_ids), sorted(pub_ids)), publisher_mc)
        r.check(len(xml_ids) <= MAX_COMPLICATIONS, "%s: at most %d complications" % (app.spec.folder, MAX_COMPLICATIONS),
                "it defines %d - Connect IQ refuses more than %d per app" % (len(xml_ids), MAX_COMPLICATIONS), publisher_mc)
        r.check(set(app.publisher_ids) == set(app.spec.rows), "%s: every Publisher id is classified" % app.spec.folder,
                "Publisher.mc: %s; check_contract.py APPS: %s - say which Terminal row a new id lands on"
                % (sorted(app.publisher_ids), sorted(app.spec.rows)), publisher_mc)

        # Labels: a Claude meter must reach its Claude Terminal row; anything else must not
        # carry the word the faces gate on, or Claude Grid / Terminal would take it for Claude.
        for name, cid in sorted(app.publisher_ids.items(), key=lambda kv: kv[1]):
            if cid not in app.complication_labels or name not in app.spec.rows:
                continue  # already reported above; no label to test
            label, want = app.complication_labels[cid], app.spec.rows[name]
            if want is None:
                r.check(CLAUDE_MARKER not in label,
                        "%s complication %d is not taken for a Claude meter" % (app.spec.folder, cid),
                        "longLabel %r contains %r" % (label, CLAUDE_MARKER), strings_xml)
            else:
                r.check(CLAUDE_MARKER in label, "%s complication %d longLabel contains %r"
                        % (app.spec.folder, cid, CLAUDE_MARKER),
                        "longLabel is %r - no face would recognise it" % label, strings_xml)
                r.check(terminal_row(label) == want, "%s complication %d (%s) lands on Claude Terminal row %s"
                        % (app.spec.folder, cid, name, want),
                        "longLabel %r maps to row %s" % (label, terminal_row(label)), strings_xml)
        for cid, label in sorted(app.complication_labels.items()):
            row = doc_comps.get((app.spec.folder, str(cid)))
            r.check(row is not None and code(row[2]) == label and code(row[4]) == terminal_row(label),
                    "CONTRACT.md %s complication %d row is current" % (app.spec.folder, cid),
                    "document row %s; code: longLabel %r, Terminal row %s" % (row, label, terminal_row(label)),
                    CONTRACT_MD)
    known = {(a.spec.folder, str(c)) for a in apps for c in a.complication_labels}
    extra = set(doc_comps) - known
    r.check(not extra, "CONTRACT.md lists no complication the watch apps lack",
            "document-only rows: %s" % sorted(extra), CONTRACT_MD)

    # 2c. The faces still match labels the way the contract describes.
    for face, files in FACE_LABEL_LITERALS.items():
        for sub, literals in files.items():
            path = FACES_DIR / face / sub
            src = read(path)
            gone = [lit for lit in literals if lit not in src]
            r.check(not gone, "%s face still matches labels with %s" % (face, ", ".join(literals)),
                    "no longer found: %s - update terminal_row()/FACE_LABEL_LITERALS and CONTRACT.md"
                    % gone, path)

    # 3. Permissions and targets. Both watch apps take the push and publish; a face must only
    # target devices every watch app targets - elsewhere some of its meters have no publisher.
    for app in apps:
        manifest = app.spec.root / "manifest.xml"
        for perm in ("ComplicationPublisher", "Communications", "Background"):
            r.check(perm in app.permissions, "%s declares %s" % (app.spec.folder, perm),
                    "permissions: %s" % sorted(app.permissions), manifest)
    common = frozenset.intersection(*(a.products for a in apps))
    r.check(all(a.products == apps[0].products for a in apps), "the watch apps target the same devices",
            "; ".join("%s: %s" % (a.spec.folder, sorted(a.products)) for a in apps), MAIN_APP.root / "manifest.xml")
    faces = sorted(p.parent for p in FACES_DIR.glob("*/manifest.xml"))
    r.check(bool(faces), "at least one face found under garmin/faces/", "no */manifest.xml", FACES_DIR)
    for face_dir in faces:
        _, products, perms = manifest_facts(face_dir / "manifest.xml")
        r.check("ComplicationSubscriber" in perms, "%s face declares ComplicationSubscriber" % face_dir.name,
                "permissions: %s" % sorted(perms), face_dir / "manifest.xml")
        r.check(products <= common, "%s face targets only devices the watch apps target" % face_dir.name,
                "face-only devices: %s" % sorted(products - common), face_dir / "manifest.xml")
    return r


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        report = run()
    except SourceShapeError as ex:
        log.error("cannot check the contract: %s", ex)
        return 2
    if os.environ.get("GITHUB_ACTIONS") == "true":
        # Workflow commands: each failure becomes an error annotation on the file concerned.
        for msg, where in report.failures:
            print("::error file=%s::%s" % (rel(where), msg.replace("\n", " ")))
    log.info("\n%d passed, %d failed", report.passed, len(report.failures))
    return 1 if report.failures else 0


if __name__ == "__main__":
    sys.exit(main())
