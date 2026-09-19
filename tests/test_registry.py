"""Tests for scripts/registry.py — wheel-registry module (offline, tmp_path only)."""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import registry  # noqa: E402

T1 = "2026-09-18T12:00:00Z"
T2 = "2026-09-18T13:00:00Z"

WHEEL = "tree_sitter_json-0.24.8-cp314-cp314-android_arm64_v8a.whl"
URL = (
    "https://github.com/o/r/releases/download/wheel/py3.14/"
    "tree-sitter-json/0.24.8/" + WHEEL
)


def add_args(reg_path: Path, **over) -> list[str]:
    base = {
        "--pkg": "tree-sitter-json",
        "--ver": "0.24.8",
        "--py": "3.14",
        "--py-actual": "3.14.0",
        "--wheel": WHEEL,
        "--url": URL,
        "--registry": str(reg_path),
    }
    base.update(over)
    return ["add"] + [x for kv in base.items() for x in kv]


@pytest.fixture
def reg(tmp_path):
    return tmp_path / "registry.json"


def run(capsys, argv):
    rc = registry.main(argv)
    out = capsys.readouterr()
    return rc, out.out, out.err


def test_add_new_appends(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    rc, out, _ = run(capsys, add_args(reg))
    assert rc == 0 and "added: py3.14-tree-sitter-json-0.24.8" in out
    doc = json.loads(reg.read_text())
    assert doc["schema_version"] == 1
    (e,) = doc["entries"]
    assert e["id"] == "py3.14-tree-sitter-json-0.24.8"
    assert e["layout_path"] == "py3.14/tree-sitter-json/0.24.8/"
    assert e["download_url"] == URL
    assert e["created_at"] == e["built_at"] == T1
    assert e["run_id"] is None


def test_rebuild_upserts_preserving_created_at(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg, **{"--run-id": "111"}))
    monkeypatch.setattr(registry, "now", lambda: T2)
    rc, out, _ = run(capsys, add_args(reg, **{"--run-id": "222"}))
    assert rc == 0 and "updated: py3.14-tree-sitter-json-0.24.8" in out
    (e,) = json.loads(reg.read_text())["entries"]
    assert e["created_at"] == T1 and e["built_at"] == T2
    assert e["run_id"] == 222


def test_different_python_is_different_id(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg))
    run(capsys, add_args(reg, **{"--py": "3.13", "--py-actual": "3.13.2"}))
    entries = json.loads(reg.read_text())["entries"]
    assert {e["id"] for e in entries} == {
        "py3.14-tree-sitter-json-0.24.8",
        "py3.13-tree-sitter-json-0.24.8",
    }


def test_list_and_pkg_filter(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg))
    run(capsys, add_args(reg, **{"--pkg": "numpy", "--ver": "2.4.4",
                                 "--py-actual": "3.14.0",
                                 "--wheel": "numpy-2.4.4.whl",
                                 "--url": URL.replace(WHEEL, "numpy-2.4.4.whl").replace(
                                     "tree-sitter-json/0.24.8", "numpy/2.4.4")}))
    rc, out, _ = run(capsys, ["list", "--registry", str(reg)])
    assert rc == 0 and "numpy" in out and "tree-sitter-json" in out
    rc, out, _ = run(capsys, ["list", "--pkg", "numpy", "--registry", str(reg)])
    assert "tree-sitter-json" not in out and "py3.14-numpy-2.4.4" in out


def test_search_matches_pkg_and_id(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg))
    rc, out, _ = run(capsys, ["search", "JSON", "--registry", str(reg)])
    assert rc == 0 and "py3.14-tree-sitter-json-0.24.8" in out
    rc, out, _ = run(capsys, ["search", "nope-xyz", "--registry", str(reg)])
    assert rc == 0 and "py3.14-" not in out


def test_url_prints_only_the_url(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg))
    rc, out, _ = run(capsys, ["url", "py3.14-tree-sitter-json-0.24.8",
                              "--registry", str(reg)])
    assert rc == 0 and out.strip() == URL


def test_get_prints_entry_json(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    run(capsys, add_args(reg))
    rc, out, _ = run(capsys, ["get", "py3.14-tree-sitter-json-0.24.8",
                              "--registry", str(reg)])
    assert rc == 0 and json.loads(out)["pkg"] == "tree-sitter-json"


def test_unknown_id_exits_1(reg, capsys):
    rc, _, err = run(capsys, ["url", "py3.14-ghost-0.0.1", "--registry", str(reg)])
    assert rc == 1 and "not found" in err
    rc, _, err = run(capsys, ["get", "py3.14-ghost-0.0.1", "--registry", str(reg)])
    assert rc == 1 and "not found" in err


def test_usage_error_exits_1(reg, capsys):
    rc, _, err = run(capsys, ["add", "--registry", str(reg)])
    assert rc == 1 and "error" in err.lower()


def test_bad_url_shape_rejected_and_file_untouched(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    rc, _, err = run(capsys, add_args(reg, **{"--url": "https://example.com/x.whl"}))
    assert rc == 2 and "download_url" in err
    assert not reg.exists() or json.loads(reg.read_text())["entries"] == []


def test_missing_field_rejected(reg, capsys, monkeypatch):
    monkeypatch.setattr(registry, "now", lambda: T1)
    argv = add_args(reg)
    argv[argv.index("--py-actual") + 1] = ""
    rc, _, err = run(capsys, argv)
    assert rc == 2 and "py_actual" in err


def test_newer_schema_version_refused(reg, capsys, monkeypatch):
    reg.write_text(json.dumps({"schema_version": 99, "entries": []}))
    monkeypatch.setattr(registry, "now", lambda: T1)
    rc, _, err = run(capsys, add_args(reg))
    assert rc == 2 and "schema_version" in err


def test_entries_stay_sorted_by_built_at(reg, capsys, monkeypatch):
    clock = {"t": T2}
    monkeypatch.setattr(registry, "now", lambda: clock["t"])
    run(capsys, add_args(reg))
    clock["t"] = T1
    run(capsys, add_args(reg, **{"--pkg": "numpy", "--ver": "2.4.4",
                                 "--wheel": "numpy-2.4.4.whl",
                                 "--url": URL.replace(WHEEL, "numpy-2.4.4.whl").replace(
                                     "tree-sitter-json/0.24.8", "numpy/2.4.4")}))
    entries = json.loads(reg.read_text())["entries"]
    assert [e["built_at"] for e in entries] == [T1, T2]
