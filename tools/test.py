"""Run offline Lua tests without starting Balatro or reading its save files."""
from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path
import sys
import unittest
from zipfile import ZipFile

from build import ZIP_PERMISSIONS, ZIP_TIMESTAMP, metadata, package_name, package_entries, TARGETS


def find_json_library(root: Path, explicit: Path | None, parser: argparse.ArgumentParser) -> Path:
    configured = explicit
    if configured is None and os.environ.get("SMODS_JSON_LIBRARY"):
        configured = Path(os.environ["SMODS_JSON_LIBRARY"])
    if configured is not None:
        configured = configured.expanduser()
        if not configured.is_file():
            parser.error(f"JSON library does not exist: {configured}")
        return configured

    candidates = [
        root / ".deps" / name / "libs" / "json" / "json.lua"
        for name in ("Steamodded", "steamodded", "smods")
    ]
    # Preserve the existing local setup as a convenience, not a prerequisite.
    if os.environ.get("APPDATA"):
        candidates.append(Path(os.environ["APPDATA"]) / "Balatro" / "Mods" / "smods" / "libs" / "json" / "json.lua")
    candidates.append(Path.home() / "AppData" / "Roaming" / "Balatro" / "Mods" / "smods" / "libs" / "json" / "json.lua")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    parser.error("Pass --json-library PATH or set SMODS_JSON_LIBRARY to Steamodded's libs/json/json.lua; no game installation is needed.")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-library", type=Path, help="Path to Steamodded libs/json/json.lua (or set SMODS_JSON_LIBRARY)")
    parser.add_argument("--check-packages", action="store_true", help="Also verify built ZIPs match current sources")
    args = parser.parse_args()
    python_tests = unittest.defaultTestLoader.discover(str(root / 'tests/python'))
    if not unittest.TextTestRunner(verbosity=1).run(python_tests).wasSuccessful():
        raise SystemExit(1)
    sys.path.insert(0, str(root / ".tools" / "python"))
    json_path = find_json_library(root, args.json_library, parser)
    json_source = json_path.read_text(encoding="utf-8")
    os.chdir(root)
    specs = sorted((root / "tests").rglob("*_spec.lua"))
    if not specs:
        parser.error("No Lua test suites were found in tests/.")
    for engine_name in ("lupa.lua51", "lupa.luajit21"):
        try:
            engine = importlib.import_module(engine_name)
        except ImportError:
            parser.error("Install the test runtimes with: python -m pip install -r requirements-dev.txt")
        for spec in specs:
            lua = engine.LuaRuntime(unpack_returned_tuples=True)
            lua.globals().TEST_JSON = lua.execute(json_source)
            lua.execute(spec.read_text(encoding="utf-8"), name="@" + spec.as_posix())
        print(f"PASS {engine_name}: {len(specs)} suites", flush=True)
    manifest = metadata(root)
    assert (root / 'src' / manifest['main_file']).is_file()
    assert {'id', 'name', 'author', 'description', 'prefix', 'main_file'} <= manifest.keys()
    for target in TARGETS if args.check_packages else ():
        archive_path = root / 'dist' / package_name(root, target)
        if not archive_path.is_file():
            parser.error(f'Missing {target} package; run python tools/build.py first.')
        with ZipFile(archive_path) as archive:
            assert archive.testzip() is None, archive_path
            contents = package_entries(root, target)
            expected = list(contents)
            assert archive.namelist() == expected, f"{archive_path}: missing, extra, duplicate or unsorted runtime files"
            for entry in archive.infolist():
                relative = entry.filename.replace("\\", "/")
                assert relative in contents, relative
                assert archive.read(entry) == contents[relative], relative
                assert entry.date_time == ZIP_TIMESTAMP, f"{archive_path}: variable timestamp on {relative}"
                assert entry.create_system == 3 and entry.external_attr == ZIP_PERMISSIONS, f"{archive_path}: variable permissions on {relative}"
    print("PASS metadata" + (" and package integrity" if args.check_packages else ""), flush=True)


if __name__ == "__main__":
    main()
