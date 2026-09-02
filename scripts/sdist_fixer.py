#!/usr/bin/env python3
"""sdist_fixer.py — auto-fix common Termux/Android breakage in extracted PyPI sdists.

Fixes implemented (all discovered on real aarch64 Termux builds):

1. tree-sitter grammar headers
   Many tree-sitter-* sdists ship `src/parser.c` but NOT the vendored
   `src/tree_sitter/{parser.h,alloc.h,array.h}` (the git submodule is skipped
   when the sdist is packed). On Linux/macOS nobody notices (prebuilt wheels);
   on Termux everything compiles from source and dies with
   `fatal error: 'tree_sitter/parser.h' file not found`.
   Fix: detect the grammar ABI generation from parser.c and install the
   matching header trio:
     - ABI 14 style ("new" names): uses `TSLexMode`, `TSFieldMapSlice`,
       TSLanguage field `.version`, NO supertype fields.
     - ABI 15 style ("old" names): uses `TSLexerMode`, `TSMapSlice`,
       TSLanguage field `.abi_version`, WITH supertype_* fields.
   Mixing generations silently corrupts the TSLanguage struct layout, so the
   correct vintage matters.

2. missing external scanners
   If parser.c references `..._external_scanner_create` but `src/scanner.c`
   (or .cc) is missing from the sdist, fetch it from the grammar's GitHub repo
   (discovered via PKG-INFO Homepage), trying tags `v<version>` and `<version>`.
   Without it the wheel builds but dlopen fails at import time with
   "cannot locate symbol ..._external_scanner_create".

3. missing quoted includes in scanners (common/scanner.h pattern)
   tree-sitter-php and tree-sitter-typescript ship scanner.c files that
   `#include "../../common/scanner.h"` — but `common/` is not packed.
   Any unresolvable quoted include inside a scanner file is fetched from the
   GitHub repo at the same repo-relative path.

Usage:
    python3 sdist_fixer.py --headers <headers_dir> <extracted_sdist_root>

Prints one JSON line at the end: {"fixes": [...], "warnings": [...]}
"""

import argparse
import glob
import json
import os
import re
import shutil
import sys
import urllib.request

TRIO = ("parser.h", "alloc.h", "array.h")
UA = {"User-Agent": "termux-wheel-forge/1.0"}


def log(msg: str) -> None:
    print(f"[fixer] {msg}", flush=True)


def http_get(url: str, timeout: int = 60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def gh_raw(owner: str, repo: str, version: str, path: str):
    """Fetch a file from GitHub trying v<version> then <version> tags."""
    if not version:
        tags = ("main", "master")
    else:
        tags = (f"v{version}", version)
    for tag in tags:
        url = f"https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{path}"
        try:
            return http_get(url), url
        except Exception:
            continue
    return None, None


def parse_github_url(url):
    if not url:
        return None, None
    m = re.match(r"https?://github\.com/([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+?)(?:\.git)?(?:/|$)", url.strip())
    if not m:
        return None, None
    return m.group(1), m.group(2)


def find_meta(root: str) -> dict:
    meta = {}
    pkginfo = os.path.join(root, "PKG-INFO")
    if os.path.isfile(pkginfo):
        text = open(pkginfo, errors="ignore").read()
        m = re.search(r"^Home-page:\s*(\S+)", text, re.M)
        if m:
            meta["homepage"] = m.group(1)
        m = re.search(r"^Project-URL:\s*Homepage,\s*(\S+)", text, re.M)
        if m:
            meta["homepage"] = m.group(1)
        m = re.search(r"^Name:\s*(\S+)", text, re.M)
        if m:
            meta["name"] = m.group(1)
        m = re.search(r"^Version:\s*(\S+)", text, re.M)
        if m:
            meta["version"] = m.group(1)
    if not (meta.get("name") and meta.get("version")):
        base = os.path.basename(os.path.normpath(root))
        m = re.match(r"(.+)-([0-9][^-]*)$", base)
        if m:
            meta.setdefault("name", m.group(1))
            meta.setdefault("version", m.group(2))
    owner, repo = parse_github_url(meta.get("homepage"))
    meta["owner"], meta["repo"] = owner, repo
    return meta


def find_parser_c_files(root: str):
    hits = set()
    for pattern in (
        os.path.join(root, "src", "parser.c"),
        os.path.join(root, "*", "src", "parser.c"),
        os.path.join(root, "*", "*", "src", "parser.c"),
    ):
        for p in glob.glob(pattern):
            hits.add(os.path.dirname(p))
    return sorted(hits)


def ensure_ts_headers(srcdir: str, headers_root: str, fixes: list, warns: list) -> None:
    parser_c = os.path.join(srcdir, "parser.c")
    src = open(parser_c, errors="ignore").read()
    if "tree_sitter/parser.h" not in src:
        return
    abi = "abi15" if re.search(r"\bTSLexerMode\b", src) else "abi14"
    vintage = os.path.join(headers_root, abi)
    if not os.path.isdir(vintage):
        warns.append(f"headers for {abi} not found at {vintage}")
        return
    dst_dir = os.path.join(srcdir, "tree_sitter")
    os.makedirs(dst_dir, exist_ok=True)
    for h in TRIO:
        dst = os.path.join(dst_dir, h)
        if os.path.exists(dst):
            continue
        src_h = os.path.join(vintage, h)
        if not os.path.isfile(src_h):
            warns.append(f"missing header {src_h}")
            continue
        shutil.copy(src_h, dst)
        fixes.append(f"installed {abi}/{h} -> {os.path.relpath(dst, srcdir)}")


def expects_external_scanner(srcdir: str) -> bool:
    parser_c = os.path.join(srcdir, "parser.c")
    if not os.path.isfile(parser_c):
        return False
    return "external_scanner_create" in open(parser_c, errors="ignore").read()


def fetch_external_scanner(srcdir: str, meta: dict, fixes: list, warns: list) -> None:
    for ext in ("c", "cc"):
        if os.path.isfile(os.path.join(srcdir, f"scanner.{ext}")):
            return
    if not expects_external_scanner(srcdir):
        return
    if not (meta.get("owner") and meta.get("repo")):
        warns.append(f"{srcdir}: needs external scanner but no GitHub repo found in metadata")
        return
    for ext in ("c", "cc"):
        data, url = gh_raw(meta["owner"], meta["repo"], meta.get("version", ""), f"src/scanner.{ext}")
        if data:
            dst = os.path.join(srcdir, f"scanner.{ext}")
            open(dst, "wb").write(data)
            fixes.append(f"fetched scanner.{ext} <- {url}")
            return
    warns.append(f"{srcdir}: scanner.c/.cc not found in {meta['owner']}/{meta['repo']}")


def fix_scanner_includes(root: str, meta: dict, fixes: list, warns: list) -> None:
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn not in ("scanner.c", "scanner.cc"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, errors="ignore").read()
            for inc in re.findall(r'#\s*include\s+"([^"]+)"', text):
                base = os.path.dirname(path)
                candidates = [
                    os.path.normpath(os.path.join(base, inc)),
                    os.path.normpath(os.path.join(os.path.dirname(base), inc)),
                    os.path.normpath(os.path.join(root, inc)),
                ]
                if any(os.path.isfile(c) for c in candidates):
                    continue
                if not (meta.get("owner") and meta.get("repo")):
                    warns.append(f"{path}: missing include {inc!r} and no repo to fetch from")
                    continue
                rel = os.path.relpath(path, root)
                repo_rel = os.path.normpath(os.path.join(os.path.dirname(rel), inc))
                if repo_rel.startswith(".."):
                    repo_rel = os.path.normpath(os.path.join(os.path.dirname(os.path.dirname(rel)), inc))
                if repo_rel.startswith(".."):
                    warns.append(f"{path}: include {inc!r} resolves outside repo root")
                    continue
                data, url = gh_raw(meta["owner"], meta["repo"], meta.get("version", ""), repo_rel)
                if data:
                    dst = os.path.normpath(os.path.join(root, repo_rel))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    open(dst, "wb").write(data)
                    fixes.append(f"fetched {repo_rel} <- {url}")
                else:
                    warns.append(f"{path}: could not fetch {repo_rel} for include {inc!r}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", help="extracted sdist root directory")
    ap.add_argument("--headers", default=os.path.join(os.path.dirname(__file__), "..", "patches", "headers"),
                    help="directory containing abi14/ and abi15/ header trios")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    headers_root = os.path.abspath(args.headers)
    fixes: list = []
    warns: list = []

    meta = find_meta(root)
    log(f"package={meta.get('name')} version={meta.get('version')} repo={meta.get('owner')}/{meta.get('repo')}")

    srcdirs = find_parser_c_files(root)
    if not srcdirs:
        log("not a tree-sitter grammar (no */src/parser.c) — nothing grammar-specific to fix")
    for srcdir in srcdirs:
        ensure_ts_headers(srcdir, headers_root, fixes, warns)
        fetch_external_scanner(srcdir, meta, fixes, warns)
    if srcdirs:
        fix_scanner_includes(root, meta, fixes, warns)

    for f in fixes:
        log(f"FIX: {f}")
    for w in warns:
        log(f"WARN: {w}")
    print(json.dumps({"fixes": fixes, "warnings": warns}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
