"""Prepare a track-grouped GTSRB classification dataset."""

from __future__ import annotations

import argparse
import hashlib
import os
import random
import shutil
from collections.abc import Callable
from collections import defaultdict
from dataclasses import dataclass
from io import BufferedIOBase
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

import yaml


CLASS_IDS = tuple(range(43))
CLASS_NAMES = tuple(f"{class_id:02d}" for class_id in CLASS_IDS)
IMAGE_SUFFIXES = {".ppm", ".png", ".jpg", ".jpeg"}
GTSRB_TRAIN_URL = (
    "https://sid.erda.dk/public/archives/"
    "daaeac0d7ce1152aea9b61d9f1e19370/GTSRB-Training_fixed.zip"
)
GTSRB_TRAIN_MD5 = "513f3c79a4c5141765e10e952eaa2478"
PROJECT_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class PreparationStats:
    classes: tuple[str, ...]
    train_images: int
    val_images: int
    train_tracks: int
    val_tracks: int


def _file_md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(
    url: str,
    destination: Path,
    expected_md5: str,
    opener: Callable[[str], BufferedIOBase] = urlopen,
) -> Path:
    destination = Path(destination)
    if destination.is_file() and _file_md5(destination) == expected_md5.lower():
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    if partial.exists():
        partial.unlink()
    try:
        digest = hashlib.md5()
        with opener(url) as response, partial.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                digest.update(chunk)
        actual_md5 = digest.hexdigest()
        if actual_md5 != expected_md5.lower():
            raise ValueError(
                f"Archive MD5 mismatch: expected {expected_md5}, got {actual_md5}"
            )
        partial.replace(destination)
        return destination
    except Exception:
        if partial.exists():
            partial.unlink()
        raise


def extract_archive(archive_path: Path, destination: Path) -> Path:
    archive_path = Path(archive_path)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    destination_root = destination.resolve()
    with ZipFile(archive_path) as archive:
        for member in archive.infolist():
            target = (destination / member.filename).resolve()
            if target != destination_root and destination_root not in target.parents:
                raise ValueError(f"Archive member escapes destination: {member.filename}")
        archive.extractall(destination)
    return destination


def _is_at_or_below(path: Path, parent: Path) -> bool:
    path = path.resolve()
    parent = parent.resolve()
    return path == parent or parent in path.parents


def _training_root(source_dir: Path) -> Path:
    candidates = (
        source_dir,
        source_dir / "GTSRB" / "Training",
        source_dir / "Training",
    )
    for candidate in candidates:
        if any((candidate / class_name).is_dir() for class_name in ("00000", "00", "0")):
            return candidate
    raise FileNotFoundError(f"GTSRB training directory not found under {source_dir}")


def _class_directory(training_root: Path, class_id: int) -> Path:
    candidates = (
        training_root / f"{class_id:05d}",
        training_root / f"{class_id:02d}",
        training_root / str(class_id),
    )
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise FileNotFoundError(f"GTSRB class directory is missing for class {class_id}")


def track_key(path: Path) -> str:
    stem = path.stem
    if "_" not in stem:
        raise ValueError(f"GTSRB filename does not contain a track key: {path.name}")
    return stem.rsplit("_", 1)[0]


def _transfer(source: Path, destination: Path, image_mode: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if image_mode == "copy":
        shutil.copy2(source, destination)
    elif image_mode == "hardlink":
        os.link(source, destination)
    else:
        raise ValueError(f"Unsupported image mode: {image_mode}")


def _write_metadata(output_dir: Path) -> None:
    metadata = {
        "path": output_dir.resolve().as_posix(),
        "train": "train",
        "val": "val",
        "nc": len(CLASS_NAMES),
        "names": {class_id: name for class_id, name in enumerate(CLASS_NAMES)},
    }
    (output_dir / "dataset.yaml").write_text(
        yaml.safe_dump(metadata, sort_keys=False),
        encoding="utf-8",
    )


def prepare_dataset(
    source_dir: Path,
    output_dir: Path,
    val_ratio: float = 0.2,
    seed: int = 42,
    image_mode: str = "hardlink",
    test_dir: Path | None = None,
) -> PreparationStats:
    source_dir = Path(source_dir)
    output_dir = Path(output_dir)
    if not 0 < val_ratio < 1:
        raise ValueError("val_ratio must be between 0 and 1")
    if test_dir is not None and _is_at_or_below(output_dir, Path(test_dir)):
        raise ValueError("Output must not be inside the held-out Test directory")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"Output directory is not empty: {output_dir}")

    training_root = _training_root(source_dir)
    assignments: list[tuple[str, Path, str]] = []
    train_tracks = 0
    val_tracks = 0

    for class_id, output_class in zip(CLASS_IDS, CLASS_NAMES):
        source_class = _class_directory(training_root, class_id)
        groups: dict[str, list[Path]] = defaultdict(list)
        for image_path in sorted(source_class.iterdir()):
            if image_path.is_file() and image_path.suffix.lower() in IMAGE_SUFFIXES:
                groups[track_key(image_path)].append(image_path)
        if len(groups) < 2:
            raise ValueError(
                f"Class {class_id} needs at least two tracks for train/val splitting"
            )

        keys = sorted(groups)
        random.Random(seed + class_id).shuffle(keys)
        val_count = max(1, round(len(keys) * val_ratio))
        val_count = min(val_count, len(keys) - 1)
        validation_keys = set(keys[:val_count])
        train_tracks += len(keys) - val_count
        val_tracks += val_count

        for key in keys:
            split = "val" if key in validation_keys else "train"
            assignments.extend((split, image_path, output_class) for image_path in groups[key])

    train_images = 0
    val_images = 0
    for split, source, output_class in assignments:
        destination = output_dir / split / output_class / source.name
        _transfer(source, destination, image_mode)
        if split == "train":
            train_images += 1
        else:
            val_images += 1

    _write_metadata(output_dir)
    return PreparationStats(
        classes=CLASS_NAMES,
        train_images=train_images,
        val_images=val_images,
        train_tracks=train_tracks,
        val_tracks=val_tracks,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prepare a track-grouped GTSRB classification dataset."
    )
    parser.add_argument("--source", type=Path, help="Extracted GTSRB root")
    parser.add_argument(
        "--raw-root",
        type=Path,
        default=PROJECT_ROOT / "training" / "raw" / "gtsrb",
        help="Archive download and extraction directory",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "training" / "datasets" / "gtsrb_cls",
        help="Prepared classification dataset directory",
    )
    parser.add_argument("--download", action="store_true", help="Download the verified training archive")
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--image-mode", choices=("copy", "hardlink"), default="hardlink")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_dir = args.source
    if args.download:
        archive_path = args.raw_root / "GTSRB-Training_fixed.zip"
        download_archive(GTSRB_TRAIN_URL, archive_path, GTSRB_TRAIN_MD5)
        if not (args.raw_root / "GTSRB" / "Training").is_dir():
            extract_archive(archive_path, args.raw_root)
        source_dir = args.raw_root
    if source_dir is None:
        raise SystemExit("error: --source is required unless --download is used")

    stats = prepare_dataset(
        source_dir=source_dir,
        output_dir=args.output,
        val_ratio=args.val_ratio,
        seed=args.seed,
        image_mode=args.image_mode,
        test_dir=PROJECT_ROOT / "Test",
    )
    print("GTSRB classification dataset prepared")
    print(f"  output: {args.output}")
    print(f"  classes: {len(stats.classes)}")
    print(f"  train: images={stats.train_images}, tracks={stats.train_tracks}")
    print(f"  val: images={stats.val_images}, tracks={stats.val_tracks}")


if __name__ == "__main__":
    main()
