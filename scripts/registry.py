#!/usr/bin/env python3
"""registry.py — CRUD and queries over registry.json (wheel-registry module).

stdlib only. Pure functions (validate/upsert/load/dump) plus a thin argparse CLI.
Exit codes: 0 ok · 1 usage error / id not found · 2 schema violation.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1
REQUIRED = (
    "id", "pkg", "ver", "py_requested", "py_actual", "wheel",
    "layout_path", "download_url", "built_at", "created_at",
)
URL_RE = re.compile(
    r"^https://github\.com/[^/\s]+/[^/\s]+/releases/download/\S+\.whl$"
)


class SchemaError(Exception):
    """Registry document or entry violates the schema."""


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_id(py_requested: str, pkg: str, ver: str) -> str:
    return f"py{py_requested}-{pkg}-{ver}"


def validate_entry(entry: dict) -> None:
    for key in REQUIRED:
        value = entry.get(key)
        if not isinstance(value, str) or not value:
            raise SchemaError(f"missing/empty field: {key}")
    if not URL_RE.match(entry["download_url"]):
        raise SchemaError(
            "download_url is not a GitHub Release asset URL ending in .whl: "
            + entry["download_url"]
        )
    run_id = entry.get("run_id")
    if run_id is not None and not isinstance(run_id, int):
        raise SchemaError("run_id must be an int or null")


def load(path: Path) -> dict:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": SCHEMA_VERSION, "entries": []}
    except json.JSONDecodeError as exc:
        raise SchemaError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
        raise SchemaError("registry must be an object with an 'entries' list")
    version = doc.get("schema_version", SCHEMA_VERSION)
    if not isinstance(version, int) or version > SCHEMA_VERSION:
        raise SchemaError(
            f"registry schema_version {version!r} newer than supported {SCHEMA_VERSION}"
        )
    return doc


def dump(path: Path, doc: dict) -> None:
    doc["entries"].sort(key=lambda e: (e["built_at"], e["id"]))
    path.write_text(
        json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def upsert(entries: list[dict], entry: dict) -> list[dict]:
    """Replace by id or append. Pure; caller owns file I/O."""
    others = [e for e in entries if e["id"] != entry["id"]]
    others.append(entry)
    return sorted(others, key=lambda e: (e["built_at"], e["id"]))


def find(doc: dict, entry_id: str) -> dict | None:
    return next((e for e in doc["entries"] if e["id"] == entry_id), None)


def table(entries: list[dict]) -> str:
    cols = ("id", "py_requested", "pkg", "ver", "built_at")
    rows = [[str(e.get(c, "")) for c in cols] for e in entries]
    widths = [
        max([len(c)] + [len(r[i]) for r in rows]) for i, c in enumerate(cols)
    ]
    fmt = "  ".join(f"{{:{w}}}" for w in widths)
    return "\n".join([fmt.format(*cols)] + [fmt.format(*r) for r in rows])


def cmd_add(ns: argparse.Namespace) -> int:
    doc = load(Path(ns.registry))
    entry = {
        "id": make_id(ns.py, ns.pkg, ns.ver),
        "pkg": ns.pkg,
        "ver": ns.ver,
        "py_requested": ns.py,
        "py_actual": ns.py_actual,
        "wheel": ns.wheel,
        "layout_path": ns.layout or f"py{ns.py}/{ns.pkg}/{ns.ver}/",
        "download_url": ns.url,
        "built_at": now(),
        "created_at": now(),
        "run_id": ns.run_id,
    }
    validate_entry(entry)
    prev = find(doc, entry["id"])
    if prev:
        entry["created_at"] = prev["created_at"]
    doc["entries"] = upsert(doc["entries"], entry)
    dump(Path(ns.registry), doc)
    print(("updated: " if prev else "added: ") + entry["id"])
    return 0


def _find_or_die(ns: argparse.Namespace) -> dict | None:
    entry = find(load(Path(ns.registry)), ns.id)
    if entry is None:
        print(f"error: id not found: {ns.id}", file=sys.stderr)
    return entry


def cmd_get(ns: argparse.Namespace) -> int:
    entry = _find_or_die(ns)
    if entry is None:
        return 1
    print(json.dumps(entry, indent=2, ensure_ascii=False))
    return 0


def cmd_url(ns: argparse.Namespace) -> int:
    entry = _find_or_die(ns)
    if entry is None:
        return 1
    print(entry["download_url"])
    return 0


def cmd_list(ns: argparse.Namespace) -> int:
    entries = load(Path(ns.registry))["entries"]
    if ns.pkg:
        entries = [e for e in entries if e["pkg"] == ns.pkg]
    print(table(entries) if entries else "(registry empty)")
    return 0


def cmd_search(ns: argparse.Namespace) -> int:
    term = ns.term.lower()
    entries = [
        e for e in load(Path(ns.registry))["entries"]
        if term in e["pkg"].lower() or term in e["id"].lower()
    ]
    print(table(entries) if entries else f"(no match for {ns.term!r})")
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # usage errors exit 1, not argparse's 2
        print(f"error: {message}", file=sys.stderr)
        raise SystemExit(1)


def _registry_arg(sp: argparse.ArgumentParser) -> None:
    sp.add_argument("--registry", default=None,
                    help="registry file path (default: global --registry or "
                         "./registry.json)")


def build_parser() -> Parser:
    p = Parser(prog="registry.py", description="wheel-registry control plane")
    p.add_argument("--registry", dest="registry_global", default=None,
                   help="registry file path (default ./registry.json)")
    sub = p.add_subparsers(dest="cmd", required=True)

    add = sub.add_parser("add", help="upsert an entry")
    _registry_arg(add)
    add.add_argument("--pkg", required=True)
    add.add_argument("--ver", required=True)
    add.add_argument("--py", required=True, help="requested python minor, e.g. 3.14")
    add.add_argument("--py-actual", required=True, dest="py_actual")
    add.add_argument("--wheel", required=True, help="wheel filename")
    add.add_argument("--url", required=True, help="Release asset download URL")
    add.add_argument("--layout", default=None,
                     help="layout_path (default py<py>/<pkg>/<ver>/)")
    add.add_argument("--run-id", type=int, default=None)
    add.set_defaults(fn=cmd_add)

    for name, fn, help_ in (("get", cmd_get, "print entry JSON"),
                            ("url", cmd_url, "print download URL")):
        sp = sub.add_parser(name, help=help_)
        _registry_arg(sp)
        sp.add_argument("id")
        sp.set_defaults(fn=fn)

    lst = sub.add_parser("list", help="list entries")
    _registry_arg(lst)
    lst.add_argument("--pkg", default=None)
    lst.set_defaults(fn=cmd_list)

    sea = sub.add_parser("search", help="substring search over pkg/id")
    _registry_arg(sea)
    sea.add_argument("term")
    sea.set_defaults(fn=cmd_search)
    return p


def main(argv: list[str]) -> int:
    try:
        ns = build_parser().parse_args(argv)
    except SystemExit as exc:  # argparse usage error -> honor exit-code contract
        return int(exc.code or 1)
    ns.registry = (ns.registry or getattr(ns, "registry_global", None)
                   or "registry.json")
    try:
        return ns.fn(ns)
    except SchemaError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
