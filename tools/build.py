"""Build reproducible WorldLine distributions without a game installation."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
from zipfile import ZIP_STORED, ZipFile, ZipInfo

ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
ZIP_PERMISSIONS = 0o100644 << 16
TARGETS = ("manual", "thunderstore")
MODULE_DIRS = ("domain", "runtime", "storage", "ui", "video", "platform", "workers", "localization")


def metadata(root: Path) -> dict:
    result = json.loads((root / "src/WorldLine.json").read_text(encoding="utf-8"))
    if result.get("id") != "WorldLine" or result.get("name") != "WorldLine":
        raise ValueError("WorldLine manifest identity is invalid")
    if not re.fullmatch(r"\d+\.\d+\.\d+", result.get("version", "")):
        raise ValueError("WorldLine requires a three-part numeric version")
    return result


def runtime_files(root: Path) -> list[Path]:
    """Explicit source roots exclude tools, tests, player data and previews."""
    source = root / "src"
    manifest = metadata(root)
    paths = {source / name for name in ("main.lua", "loader.lua", "WorldLine.json", "lovely.toml")}
    for directory in MODULE_DIRS:
        paths.update((source / directory).rglob("*.lua"))
    icon = source / "assets/1x/modicon.png"
    if manifest.get("icon_path") != "modicon.png":
        raise ValueError("Native Mods icon must be modicon.png")
    paths.add(icon)
    for path in paths:
        if not path.is_file():
            raise ValueError(f"Runtime file is missing: {path}")
        if any(item.is_symlink() for item in (path, *path.parents)) or not path.resolve().is_relative_to(source.resolve()):
            raise ValueError(f"Cannot package linked runtime file: {path}")
    if source / manifest["main_file"] not in paths:
        raise ValueError("main_file is outside the runtime allowlist")
    return sorted(paths, key=lambda path: path.relative_to(source).as_posix())


def package_name(root: Path, target: str = "manual") -> str:
    if target not in TARGETS:
        raise ValueError("Unknown package target")
    suffix = "-Thunderstore" if target == "thunderstore" else ""
    return f"WorldLine-{metadata(root)['version']}{suffix}.zip"


def thunderstore_metadata(root: Path) -> dict:
    result = json.loads((root / "thunderstore/manifest.json").read_text(encoding="utf-8"))
    if result.get("name") != "WorldLine" or result.get("version_number") != metadata(root)["version"]:
        raise ValueError("Thunderstore name/version does not match WorldLine")
    if not isinstance(result.get("description"), str) or not 1 <= len(result["description"]) <= 250:
        raise ValueError("Thunderstore description must contain 1 to 250 characters")
    if result.get("dependencies") != ["Steamodded-Steamodded-26.1002.0", "Thunderstore-lovely-0.10.0"]:
        raise ValueError("Review tested dependencies before changing them")
    icon = (root / "src/assets/1x/modicon.png").read_bytes()
    if icon[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" or struct.unpack(">II", icon[16:24]) != (256, 256):
        raise ValueError("Thunderstore icon must be a 256x256 PNG")
    return result


def thunderstore_readme(root: Path) -> bytes:
    """Use Markdown where Thunderstore may sanitize picture/source HTML."""
    text = (root / "README.md").read_text(encoding="utf-8")
    marker = "<!-- WORLDLINE_HEADER_END -->"
    if marker not in text:
        raise ValueError("README hero header marker is missing")
    header = "# WorldLine\n\n[Usage guide](https://github.com/KraHsu/balatro-worldline/blob/main/docs/usage.md) · [简体中文](https://github.com/KraHsu/balatro-worldline/blob/main/README_CN.md)\n\n"
    body = text.split(marker, 1)[1].lstrip()
    # Relative repository links do not resolve on a Thunderstore package page.
    body = re.sub(r"(\]\()((?!https?://|#)[^)]+)(\))",
                  r"\1https://github.com/KraHsu/balatro-worldline/blob/main/\2\3", body)
    return (header + body).encode("utf-8")


def package_entries(root: Path, target: str = "manual") -> dict[str, bytes]:
    if target not in TARGETS:
        raise ValueError("Unknown package target")
    entries = {f"WorldLine/{path.relative_to(root / 'src').as_posix()}": path.read_bytes() for path in runtime_files(root)}
    entries["WorldLine/LICENSE"] = (root / "LICENSE").read_bytes()
    if target == "thunderstore":
        thunderstore_metadata(root)
        entries.update({
            "manifest.json": (root / "thunderstore/manifest.json").read_bytes(),
            "icon.png": (root / "src/assets/1x/modicon.png").read_bytes(),
            "README.md": thunderstore_readme(root),
            "CHANGELOG.md": (root / "CHANGELOG.md").read_bytes(),
            "LICENSE": (root / "LICENSE").read_bytes(),
            "NOTICE.md": (root / "NOTICE.md").read_bytes(),
        })
    return dict(sorted(entries.items()))


def build_package(root: Path, output_dir: Path, target: str = "manual") -> Path:
    entries = package_entries(root, target)
    destination = output_dir / package_name(root, target)
    output_dir.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_STORED) as archive:
        for name, data in entries.items():
            entry = ZipInfo(name, date_time=ZIP_TIMESTAMP)
            entry.create_system = 3
            entry.external_attr = ZIP_PERMISSIONS
            entry.compress_type = ZIP_STORED
            archive.writestr(entry, data)
    return destination


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=root / "dist")
    parser.add_argument("--target", choices=(*TARGETS, "all"), default="all")
    parser.add_argument("--github-output", type=Path, help="Write package paths and version to a GitHub Actions output file")
    args = parser.parse_args()
    try:
        targets = TARGETS if args.target == "all" else (args.target,)
        paths = {target: build_package(root, args.output_dir, target) for target in targets}
        for path in paths.values():
            print(path)
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8", newline="\n") as output:
                output.write(f"version={metadata(root)['version']}\n")
                for target, path in paths.items():
                    output.write(f"{target}={path.as_posix()}\n")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Build failed: {error}\n")


if __name__ == "__main__":
    main()
