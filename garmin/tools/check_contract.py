#!/usr/bin/env python3
"""Verify the phone <-> watch app <-> face contract (garmin/CONTRACT.md) across all three codebases.

The Android app, the Connect IQ watch app and the watch faces are compiled separately, so nothing
checks that they agree on the values they exchange - the app id the phone sends to, the message
keys, the complication ids, and the complication label text the faces match on. A mismatch builds
cleanly and fails silently on the watch. This script reads each side's SOURCE (no build needed)
plus the tables in CONTRACT.md, and fails when any two disagree - so the document cannot drift
from the code either.

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
WATCH_APP = GARMIN / "watch-app"
WATCH_MANIFEST = WATCH_APP / "manifest.xml"
SNAPSHOT_MC = WATCH_APP / "source" / "Snapshot.mc"
PUBLISHER_MC = WATCH_APP / "source" / "Publisher.mc"
COMPLICATIONS_XML = WATCH_APP / "resources" / "complications.xml"
STRINGS_XML = WATCH_APP / "resources" / "strings" / "strings.xml"
FACES_DIR = GARMIN / "faces"

# Connect IQ manifests put every element in this namespace (xmlns:iq=...), so ElementTree sees
# tags as "{uri}application" rather than "iq:application".
IQ_NS = "{http://www.garmin.com/xml/connectiq}"

# Snapshot.mc constant names whose keys Snapshot.store() REQUIRES - it rejects a message without
# them - so the phone must send them unconditionally.
REQUIRED_SNAPSHOT_CONSTS = ("K_FIVE", "K_WEEK")
# The per-model keys: sent all together or not at all (a message without them clears the meter).
MODEL_SNAPSHOT_CONSTS = ("K_MODEL", "K_MODEL_RESET", "K_MODEL_NAME")

# Every face recognises a Claude meter by this substring of its longLabel.
CLAUDE_MARKER = "Claude"
# The Claude Terminal row each Publisher complication must land on (ClaudeFaceView.slotFor
# returns 0 / 1 / 2 = the 5H / 1W / model rows).
TERMINAL_ROW_FOR_PUBLISHER_ID = {"ID_FIVE": "5H", "ID_WEEK": "1W", "ID_MODEL": "model"}

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


# ---- the three sides ------------------------------------------------------------------------

@dataclass(frozen=True)
class Phone:
    app_id: str
    always_keys: frozenset[str]       # in the mutableMapOf(...) literal: sent on every push
    conditional_keys: frozenset[str]  # payload["k"] = ... inside the `if (x != null) { }` guard
    unguarded_keys: frozenset[str]    # payload["k"] = ... anywhere else in payloadOf() (must be none)


# Kotlin `payload["k"] = value` assignment; group 1 = the key.
ASSIGN = r'payload\["(\w+)"\]\s*='


def parse_phone() -> Phone:
    kt = read(WATCH_BRIDGE)
    app_id = search(r'WATCH_APP_ID\s*=\s*"([0-9a-fA-F]{32})"', kt, WATCH_BRIDGE, "WATCH_APP_ID").group(1)
    body = search(r"fun payloadOf\(.*?\{(.*?)\n\s*return payload", kt, WATCH_BRIDGE,
                  "payloadOf() ... return payload", re.S).group(1)
    literal = search(r"mutableMapOf<String, Any>\((.*?)\n\s*\)", body, WATCH_BRIDGE,
                     "the mutableMapOf(...) payload literal", re.S).group(1)
    always = frozenset(re.findall(r'"(\w+)"\s+to\b', literal))
    if not always:
        raise SourceShapeError("%s: payloadOf() literal has no \"key\" to value entries" % rel(WATCH_BRIDGE))
    # The per-model keys must be assigned only inside the null-guard, so they travel together.
    # The guard's closing brace is the first line holding only "}" at the guard's own indent.
    guard = search(r"\n([ \t]*)if \(\w+ != null\) \{\n(.*?)\n\1\}", body, WATCH_BRIDGE,
                   "the `if (model != null) { ... }` guard in payloadOf()", re.S)
    conditional = frozenset(re.findall(ASSIGN, guard.group(2)))
    outside = body[:guard.start()] + body[guard.end():]
    unguarded = frozenset(re.findall(ASSIGN, outside))
    return Phone(app_id.lower(), always, conditional, unguarded)


@dataclass(frozen=True)
class WatchApp:
    app_id: str
    products: frozenset[str]
    permissions: frozenset[str]
    snapshot_keys: dict[str, str]           # Snapshot.mc constant name -> key
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


def parse_watch_app() -> WatchApp:
    app_id, products, perms = manifest_facts(WATCH_MANIFEST)

    snapshot = dict(re.findall(r'const\s+(K_\w+)\s*=\s*"(\w+)"\s*;', read(SNAPSHOT_MC)))
    missing = [c for c in REQUIRED_SNAPSHOT_CONSTS + MODEL_SNAPSHOT_CONSTS if c not in snapshot]
    if missing:
        raise SourceShapeError("%s: constants %s not found" % (rel(SNAPSHOT_MC), missing))

    publisher = {name: int(v) for name, v in re.findall(r"const\s+(ID_\w+)\s*=\s*(\d+)\s*;", read(PUBLISHER_MC))}
    missing = [c for c in TERMINAL_ROW_FOR_PUBLISHER_ID if c not in publisher]
    if missing:
        raise SourceShapeError("%s: constants %s not found" % (rel(PUBLISHER_MC), missing))

    strings = {s.get("id"): (s.text or "") for s in parse_xml(STRINGS_XML).iter("string")}
    labels: dict[int, str] = {}
    for comp in parse_xml(COMPLICATIONS_XML).iter("complication"):
        raw_id, long_label = comp.get("id"), comp.get("longLabel")
        if raw_id is None or not raw_id.isdigit() or long_label is None:
            raise SourceShapeError("%s: a <complication> lacks a numeric id or a longLabel" % rel(COMPLICATIONS_XML))
        if long_label.startswith("@Strings."):
            ref = long_label[len("@Strings."):]
            if ref not in strings:
                raise SourceShapeError("%s: longLabel %s has no <string id=%r> in %s"
                                       % (rel(COMPLICATIONS_XML), long_label, ref, rel(STRINGS_XML)))
            long_label = strings[ref]
        labels[int(raw_id)] = long_label
    return WatchApp(app_id, products, perms, snapshot, publisher, labels)


def terminal_row(long_label: str) -> str | None:
    """Python twin of ClaudeFaceView.slotFor (Monkey C String.find is case-sensitive, like `in`)."""
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


# ---- the checks -----------------------------------------------------------------------------

def run() -> Report:
    r = Report()
    phone, watch = parse_phone(), parse_watch_app()
    md = read(CONTRACT_MD)

    # 1a. The app id the phone sends to.
    r.check(phone.app_id == watch.app_id, "phone WATCH_APP_ID == watch-app manifest id",
            "WatchBridge.kt has %s, manifest.xml has %s" % (phone.app_id, watch.app_id), WATCH_BRIDGE)
    doc_ids = set(re.findall(r"`([0-9a-fA-F]{32})`", "\n".join("|".join(row) for row in doc_table(md, "app-id"))))
    r.check(doc_ids == {watch.app_id}, "CONTRACT.md app id is current",
            "document lists %s, code has %s" % (sorted(doc_ids), watch.app_id), CONTRACT_MD)

    # 1b. Message keys.
    watch_keys = set(watch.snapshot_keys.values())
    phone_keys = set(phone.always_keys | phone.conditional_keys | phone.unguarded_keys)
    r.check(phone_keys == watch_keys, "phone payload keys == Snapshot.mc keys",
            "phone only: %s; watch only: %s" % (sorted(phone_keys - watch_keys), sorted(watch_keys - phone_keys)),
            WATCH_BRIDGE)
    required = {watch.snapshot_keys[c] for c in REQUIRED_SNAPSHOT_CONSTS}
    r.check(required <= phone.always_keys, "keys the watch requires are sent on every push",
            "Snapshot.store() rejects a message without %s; sent unconditionally: %s"
            % (sorted(required), sorted(phone.always_keys)), WATCH_BRIDGE)
    model = {watch.snapshot_keys[c] for c in MODEL_SNAPSHOT_CONSTS}
    r.check(phone.conditional_keys == model, "per-model keys are sent together, and only they are conditional",
            "conditional on the phone: %s; per-model keys: %s" % (sorted(phone.conditional_keys), sorted(model)),
            WATCH_BRIDGE)
    r.check(not (phone.always_keys & model), "no per-model key is in the always-sent literal",
            "always sent: %s - they must be omitted when the account has no model cap"
            % sorted(phone.always_keys & model), WATCH_BRIDGE)
    r.check(not phone.unguarded_keys, "no payload key is assigned outside the model null-guard",
            "assigned outside it: %s - a lone model key would half-set the model meter"
            % sorted(phone.unguarded_keys), WATCH_BRIDGE)
    doc_rows = {code(row[0]): row for row in doc_table(md, "payload")}
    r.check(set(doc_rows) == watch_keys, "CONTRACT.md payload table lists exactly the keys",
            "document only: %s; code only: %s" % (sorted(set(doc_rows) - watch_keys - {None}),
                                                   sorted(watch_keys - set(doc_rows))), CONTRACT_MD)
    doc_always = {k for k, row in doc_rows.items() if len(row) > 2 and row[2] == "always"}
    r.check(doc_always == set(phone.always_keys), "CONTRACT.md 'Sent: always' matches the phone",
            "document says always: %s; phone always sends: %s" % (sorted(doc_always), sorted(phone.always_keys)),
            CONTRACT_MD)

    # 2a. Complication ids.
    xml_ids, pub_ids = set(watch.complication_labels), set(watch.publisher_ids.values())
    r.check(xml_ids == pub_ids, "complications.xml ids == Publisher.mc ids",
            "xml: %s; Publisher: %s" % (sorted(xml_ids), sorted(pub_ids)), PUBLISHER_MC)

    # 2b. Labels: every face's "Claude" gate, and Claude Terminal's row mapping.
    for name, cid in sorted(watch.publisher_ids.items(), key=lambda kv: kv[1]):
        if cid not in watch.complication_labels:
            continue  # already reported by the id check above; no label to test
        label = watch.complication_labels[cid]
        r.check(CLAUDE_MARKER in label, "complication %d longLabel contains %r" % (cid, CLAUDE_MARKER),
                "longLabel is %r - no face would recognise it" % label, STRINGS_XML)
        want, got = TERMINAL_ROW_FOR_PUBLISHER_ID[name], terminal_row(label)
        r.check(got == want, "complication %d (%s) lands on Claude Terminal row %s" % (cid, name, want),
                "longLabel %r maps to row %s" % (label, got), STRINGS_XML)
    doc_comps = {code(row[0]): row for row in doc_table(md, "complications")}
    for cid, label in sorted(watch.complication_labels.items()):
        row = doc_comps.get(str(cid))
        r.check(row is not None and len(row) > 3 and code(row[1]) == label
                and code(row[3]) == terminal_row(label),
                "CONTRACT.md complication %d row is current" % cid,
                "document row %s; code: longLabel %r, Terminal row %s" % (row, label, terminal_row(label)),
                CONTRACT_MD)
    extra = set(doc_comps) - {str(c) for c in watch.complication_labels}
    r.check(not extra, "CONTRACT.md lists no complication the watch app lacks",
            "document-only ids: %s" % sorted(e for e in extra if e), CONTRACT_MD)

    # 2c. The faces still match labels the way the contract describes.
    for face, files in FACE_LABEL_LITERALS.items():
        for sub, literals in files.items():
            path = FACES_DIR / face / sub
            src = read(path)
            gone = [lit for lit in literals if lit not in src]
            r.check(not gone, "%s face still matches labels with %s" % (face, ", ".join(literals)),
                    "no longer found: %s - update terminal_row()/FACE_LABEL_LITERALS and CONTRACT.md"
                    % gone, path)

    # 3. Permissions and targets, for every face present (a new face is picked up automatically).
    r.check("ComplicationPublisher" in watch.permissions, "watch app declares ComplicationPublisher",
            "permissions: %s" % sorted(watch.permissions), WATCH_MANIFEST)
    faces = sorted(p.parent for p in FACES_DIR.glob("*/manifest.xml"))
    r.check(bool(faces), "at least one face found under garmin/faces/", "no */manifest.xml", FACES_DIR)
    for face_dir in faces:
        _, products, perms = manifest_facts(face_dir / "manifest.xml")
        r.check("ComplicationSubscriber" in perms, "%s face declares ComplicationSubscriber" % face_dir.name,
                "permissions: %s" % sorted(perms), face_dir / "manifest.xml")
        r.check(products <= watch.products, "%s face targets only devices the watch app targets" % face_dir.name,
                "face-only devices: %s" % sorted(products - watch.products), face_dir / "manifest.xml")
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
