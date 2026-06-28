#!/usr/bin/env python3
"""Build a styled release DMG for Scribe using create-dmg.

This script owns the DMG packaging policy so the GitHub Actions workflow can
stay focused on orchestration. The workflow decides *when* to package, while
this script decides *how* the installer disk image is assembled:

1. Validate the archived app bundle that release CI produced.
2. Stage a copy of the app into a clean folder (no Applications symlink —
   create-dmg adds the Applications drop-link itself via --app-drop-link).
3. Combine the committed 1x and @2x background PNGs into a multi-rep TIFF
   that Finder resolves to the right resolution per display.
4. Invoke create-dmg, which mounts a temporary RW image, uses Finder
   AppleScript to place icons at exact coordinates, then converts to UDZO.

Using create-dmg instead of dmgbuild: dmgbuild writes a DS_Store blob
directly into the image without ever opening Finder, which causes icon
positions to be ignored silently on modern macOS. create-dmg drives the
Finder process that owns the coordinate space, so positions are reliable.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# Horizontal layout: App on left, Applications folder alias on right.
# Standard macOS installer convention — drag left icon to right target.
WINDOW_WIDTH = 660
WINDOW_HEIGHT = 400
ICON_SIZE = 128
APP_ICON_X = 165
APP_ICON_Y = 185
APPLICATIONS_X = 495
APPLICATIONS_Y = 185


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a styled Scribe release DMG with create-dmg."
    )
    parser.add_argument(
        "--app-path",
        required=True,
        help="Path to the signed Scribe.app bundle that should be packaged.",
    )
    parser.add_argument(
        "--output-path",
        required=True,
        help="Path where the final Scribe.dmg should be written.",
    )
    parser.add_argument(
        "--background-path",
        required=True,
        help="Path to the committed 1x DMG background PNG source asset.",
    )
    parser.add_argument(
        "--background-2x-path",
        required=True,
        help="Path to the committed @2x DMG background PNG source asset.",
    )
    parser.add_argument(
        "--volume-name",
        required=True,
        help="Mounted volume name shown by Finder, for example Scribe.",
    )
    return parser.parse_args()


def run_command(
    command: list[str],
    *,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0 and not allow_failure:
        if result.stdout:
            print(result.stdout, file=sys.stderr, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}: {' '.join(command)}"
        )
    return result


def require_existing_path(path: Path, *, kind: str) -> Path:
    if not path.exists():
        raise FileNotFoundError(f"{kind} not found at {path}")
    return path.resolve()


def ensure_create_dmg_available() -> None:
    if not shutil.which("create-dmg"):
        raise RuntimeError(
            "create-dmg is not installed. Run `brew install create-dmg` before packaging."
        )


def normalize_background_image(
    source_1x_path: Path,
    source_2x_path: Path,
    destination_path: Path,
) -> None:
    """Combine 1x and @2x PNGs into a multi-rep TIFF for Finder.

    A single PNG can't carry multiple resolutions. A multi-image TIFF lets
    Finder pick the right rep per display without DPI-tagging tricks.
    """
    run_command(
        [
            "tiffutil",
            "-cathidpicheck",
            str(source_1x_path),
            str(source_2x_path),
            "-out",
            str(destination_path),
        ]
    )


def stage_app(app_path: Path, staging_root: Path) -> Path:
    """Copy the signed app into a clean staging folder and return the staged path.

    create-dmg is passed the staged .app directly (not the parent folder).
    Staging via ditto ensures symlinks, resource forks, and xattrs are intact.
    """
    staged_app_path = staging_root / app_path.name
    run_command(["ditto", str(app_path), str(staged_app_path)])
    return staged_app_path


def build_dmg(
    *,
    volume_name: str,
    staged_app_path: Path,
    output_path: Path,
    background_path: Path,
) -> None:
    if output_path.exists():
        output_path.unlink()

    # Pass the .app directly — create-dmg includes it plus the Applications
    # alias (--app-drop-link). Passing a parent folder causes create-dmg to
    # include only the folder contents without the .app itself.
    run_command(
        [
            "create-dmg",
            "--volname", volume_name,
            "--background", str(background_path),
            "--window-pos", "200", "120",
            "--window-size", str(WINDOW_WIDTH), str(WINDOW_HEIGHT),
            "--icon-size", str(ICON_SIZE),
            "--icon", staged_app_path.name, str(APP_ICON_X), str(APP_ICON_Y),
            "--hide-extension", staged_app_path.name,
            "--app-drop-link", str(APPLICATIONS_X), str(APPLICATIONS_Y),
            "--no-internet-enable",
            str(output_path),
            str(staged_app_path),
        ]
    )


def main() -> int:
    args = parse_args()
    ensure_create_dmg_available()

    app_path = require_existing_path(Path(args.app_path), kind="App bundle")
    background_1x_path = require_existing_path(
        Path(args.background_path), kind="Background asset (1x)"
    )
    background_2x_path = require_existing_path(
        Path(args.background_2x_path), kind="Background asset (@2x)"
    )
    output_path = Path(args.output_path).resolve()

    if app_path.suffix != ".app":
        raise ValueError(f"Expected a .app bundle, got {app_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="Scribe-dmg-") as temporary_root:
        temporary_root_path = Path(temporary_root)
        staging_root = temporary_root_path / "staging"
        staging_root.mkdir()

        staged_app_path = stage_app(app_path, staging_root)

        normalized_background_path = temporary_root_path / "dmg-background.tiff"
        normalize_background_image(
            background_1x_path,
            background_2x_path,
            normalized_background_path,
        )

        build_dmg(
            volume_name=args.volume_name,
            staged_app_path=staged_app_path,
            output_path=output_path,
            background_path=normalized_background_path,
        )

    print(f"Built styled DMG at {output_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # pragma: no cover — exercised by manual release validation.
        print(f"Failed to build release DMG: {error}", file=sys.stderr)
        raise SystemExit(1)
