#!/usr/bin/env python3
"""
Prepare the TT100K dataset for Ultralytics YOLO training.

Input:
    TT100K annotations JSON, usually annotations.json / annotations_all.json.

Output:
    A YOLO dataset directory:
        data.yaml
        images/{train,val,test}/
        labels/{train,val,test}/

Example:
    python tools/prepare_tt100k.py \
        --annotations /mnt/d/datasets/TT100K/annotations_all.json \
        --image-root /mnt/d/datasets/TT100K \
        --output datasets/tt100k
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


SPLITS = ("train", "val", "test")
VALID_SPLIT_NAMES = {
    "train": "train",
    "other": "val",
    "val": "val",
    "valid": "val",
    "test": "test",
}
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp"}
COMMON_45_CLASSES = (
    "i2",
    "i4",
    "i5",
    "il100",
    "il60",
    "il80",
    "io",
    "ip",
    "p10",
    "p11",
    "p12",
    "p19",
    "p23",
    "p26",
    "p27",
    "p3",
    "p5",
    "p6",
    "pg",
    "ph4",
    "ph4.5",
    "ph5",
    "pl100",
    "pl120",
    "pl20",
    "pl30",
    "pl40",
    "pl5",
    "pl50",
    "pl60",
    "pl70",
    "pl80",
    "pm20",
    "pm30",
    "pm55",
    "pn",
    "pne",
    "po",
    "pr40",
    "w13",
    "w32",
    "w55",
    "w57",
    "w59",
    "wo",
)


@dataclass(frozen=True)
class DatasetStats:
    images: dict[str, int]
    labels: dict[str, int]
    objects: dict[str, int]
    classes: list[str]
    skipped_objects: int


def load_tt100k_records(annotation_path: Path) -> list[dict[str, Any]]:
    """Load TT100K records from the common top-level imgs mapping."""
    with annotation_path.open("r", encoding="utf-8") as f:
        payload = json.load(f)

    raw_records = payload.get("imgs", payload)
    if isinstance(raw_records, dict):
        records = list(raw_records.values())
    elif isinstance(raw_records, list):
        records = raw_records
    else:
        raise ValueError("Unsupported TT100K annotation format: expected imgs dict or list")

    normalized = []
    for record in records:
        if not isinstance(record, dict):
            continue

        image_path = (
            record.get("path")
            or record.get("file_name")
            or record.get("filename")
            or record.get("name")
        )
        if not image_path:
            continue

        normalized.append(record)

    return normalized


def collect_class_counts(records: list[dict[str, Any]]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for record in records:
        for obj in record.get("objects", []):
            category = obj.get("category") or obj.get("label") or obj.get("name")
            if category:
                counts[str(category)] += 1
    return counts


def select_classes(class_counts: Counter[str], min_instances: int) -> list[str]:
    return sorted(name for name, count in class_counts.items() if count >= min_instances)


def record_image_path(record: dict[str, Any]) -> str:
    return str(
        record.get("path")
        or record.get("file_name")
        or record.get("filename")
        or record.get("name")
    )


def infer_split(relative_path: str) -> str | None:
    parts = Path(relative_path.replace("\\", "/")).parts
    for part in parts:
        split = VALID_SPLIT_NAMES.get(part.lower())
        if split:
            return split
    return None


def split_records(
    records: list[dict[str, Any]],
    val_ratio: float,
    test_ratio: float,
    seed: int,
) -> dict[str, list[dict[str, Any]]]:
    by_split = {split: [] for split in SPLITS}
    unknown = []

    for record in records:
        split = infer_split(record_image_path(record))
        if split:
            by_split[split].append(record)
        else:
            unknown.append(record)

    rng = random.Random(seed)

    if unknown:
        rng.shuffle(unknown)
        test_count = round(len(unknown) * test_ratio)
        val_count = round(len(unknown) * val_ratio)
        by_split["test"].extend(unknown[:test_count])
        by_split["val"].extend(unknown[test_count : test_count + val_count])
        by_split["train"].extend(unknown[test_count + val_count :])

    if not by_split["val"] and len(by_split["train"]) > 1 and val_ratio > 0:
        rng.shuffle(by_split["train"])
        val_count = max(1, round(len(by_split["train"]) * val_ratio))
        by_split["val"] = by_split["train"][:val_count]
        by_split["train"] = by_split["train"][val_count:]

    return by_split


def resolve_image_path(image_root: Path, relative_path: str) -> Path:
    relative = Path(relative_path.replace("\\", "/"))
    candidates = [
        image_root / relative,
        image_root / "data" / relative,
        image_root / "images" / relative,
    ]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return candidates[0]


def image_size(record: dict[str, Any], image_path: Path) -> tuple[int, int]:
    width = record.get("width") or record.get("w")
    height = record.get("height") or record.get("h")
    if width and height:
        return int(width), int(height)

    try:
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError(
            "Pillow is required when TT100K annotations do not include width/height"
        ) from exc

    with Image.open(image_path) as img:
        return img.size


def parse_bbox(obj: dict[str, Any]) -> tuple[float, float, float, float] | None:
    bbox = obj.get("bbox") or obj.get("box")
    if not bbox:
        return None

    if isinstance(bbox, dict):
        try:
            xmin = float(bbox.get("xmin", bbox.get("x1")))
            ymin = float(bbox.get("ymin", bbox.get("y1")))
            xmax = float(bbox.get("xmax", bbox.get("x2")))
            ymax = float(bbox.get("ymax", bbox.get("y2")))
            return xmin, ymin, xmax, ymax
        except (TypeError, ValueError):
            return None

    if isinstance(bbox, list) and len(bbox) == 4:
        try:
            xmin, ymin, xmax, ymax = (float(value) for value in bbox)
            return xmin, ymin, xmax, ymax
        except (TypeError, ValueError):
            return None

    return None


def to_yolo_line(
    obj: dict[str, Any],
    width: int,
    height: int,
    class_to_id: dict[str, int],
) -> str | None:
    category = obj.get("category") or obj.get("label") or obj.get("name")
    category_name = str(category)
    if category_name not in class_to_id:
        return None

    bbox = parse_bbox(obj)
    if bbox is None:
        return None

    xmin, ymin, xmax, ymax = bbox
    xmin = max(0.0, min(float(width), xmin))
    xmax = max(0.0, min(float(width), xmax))
    ymin = max(0.0, min(float(height), ymin))
    ymax = max(0.0, min(float(height), ymax))

    box_width = xmax - xmin
    box_height = ymax - ymin
    if box_width <= 0 or box_height <= 0:
        return None

    x_center = (xmin + xmax) / 2 / width
    y_center = (ymin + ymax) / 2 / height
    norm_width = box_width / width
    norm_height = box_height / height

    return (
        f"{class_to_id[category_name]} "
        f"{x_center:.6f} {y_center:.6f} {norm_width:.6f} {norm_height:.6f}"
    )


def safe_stem(relative_path: str) -> str:
    path = Path(relative_path.replace("\\", "/"))
    parts = [part for part in path.with_suffix("").parts if part not in (".", "")]
    return "__".join(parts)


def transfer_image(source: Path, destination: Path, mode: str) -> None:
    if mode == "none":
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        destination.unlink()

    if mode == "copy":
        shutil.copy2(source, destination)
    elif mode == "hardlink":
        os.link(source, destination)
    elif mode == "symlink":
        os.symlink(source, destination)
    else:
        raise ValueError(f"Unsupported image transfer mode: {mode}")


def write_data_yaml(output_dir: Path, classes: list[str]) -> Path:
    yaml_path = output_dir / "data.yaml"
    lines = [
        "path: .",
        "train: images/train",
        "val: images/val",
        "test: images/test",
        f"nc: {len(classes)}",
        "names:",
    ]
    for class_id, name in enumerate(classes):
        lines.append(f"  {class_id}: {json.dumps(name, ensure_ascii=False)}")

    yaml_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return yaml_path


def convert_dataset(
    annotation_path: Path,
    image_root: Path,
    output_dir: Path,
    min_instances: int = 1,
    val_ratio: float = 0.1,
    test_ratio: float = 0.1,
    seed: int = 42,
    image_mode: str = "copy",
    class_names: Sequence[str] | None = None,
) -> DatasetStats:
    records = load_tt100k_records(annotation_path)
    if class_names is None:
        class_counts = collect_class_counts(records)
        classes = select_classes(class_counts, min_instances)
    else:
        classes = [str(name).strip() for name in class_names if str(name).strip()]
        if len(classes) != len(set(classes)):
            raise ValueError("Class names must be unique")
    if not classes:
        raise ValueError("No classes selected. Lower --min-instances or check annotations.")

    class_to_id = {name: index for index, name in enumerate(classes)}
    by_split = split_records(records, val_ratio=val_ratio, test_ratio=test_ratio, seed=seed)

    for split in SPLITS:
        (output_dir / "images" / split).mkdir(parents=True, exist_ok=True)
        (output_dir / "labels" / split).mkdir(parents=True, exist_ok=True)

    image_counts = {split: 0 for split in SPLITS}
    label_counts = {split: 0 for split in SPLITS}
    object_counts = {split: 0 for split in SPLITS}
    skipped_objects = 0

    for split, split_records_ in by_split.items():
        for record in split_records_:
            relative_path = record_image_path(record)
            source_image = resolve_image_path(image_root, relative_path)
            if not source_image.exists():
                raise FileNotFoundError(f"Image not found: {source_image}")

            width, height = image_size(record, source_image)
            output_stem = safe_stem(relative_path)
            suffix = source_image.suffix.lower()
            if suffix not in IMAGE_SUFFIXES:
                suffix = ".jpg"

            image_destination = output_dir / "images" / split / f"{output_stem}{suffix}"
            label_destination = output_dir / "labels" / split / f"{output_stem}.txt"

            lines = []
            for obj in record.get("objects", []):
                line = to_yolo_line(obj, width, height, class_to_id)
                if line is None:
                    skipped_objects += 1
                    continue
                lines.append(line)

            transfer_image(source_image, image_destination, image_mode)
            label_destination.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")

            image_counts[split] += 1
            label_counts[split] += 1
            object_counts[split] += len(lines)

    write_data_yaml(output_dir, classes)

    return DatasetStats(
        images=image_counts,
        labels=label_counts,
        objects=object_counts,
        classes=classes,
        skipped_objects=skipped_objects,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert TT100K annotations to a YOLO training dataset.",
    )
    parser.add_argument("--annotations", required=True, type=Path, help="TT100K JSON annotation file")
    parser.add_argument("--image-root", required=True, type=Path, help="TT100K root or image root directory")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("datasets/tt100k"),
        help="Output YOLO dataset directory, relative to current working directory by default",
    )
    parser.add_argument(
        "--min-instances",
        type=int,
        default=1,
        help="Keep classes with at least this many annotated objects",
    )
    parser.add_argument(
        "--common-45",
        action="store_true",
        help="Use the fixed TT100K common 45-class vocabulary",
    )
    parser.add_argument("--val-ratio", type=float, default=0.1, help="Validation ratio when TT100K has no val split")
    parser.add_argument("--test-ratio", type=float, default=0.1, help="Test ratio for records without official split")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for generated splits")
    parser.add_argument(
        "--image-mode",
        choices=("copy", "hardlink", "symlink", "none"),
        default="copy",
        help="How to place images in the YOLO directory",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    stats = convert_dataset(
        annotation_path=args.annotations,
        image_root=args.image_root,
        output_dir=args.output,
        min_instances=args.min_instances,
        val_ratio=args.val_ratio,
        test_ratio=args.test_ratio,
        seed=args.seed,
        image_mode=args.image_mode,
        class_names=COMMON_45_CLASSES if args.common_45 else None,
    )

    print("TT100K YOLO dataset prepared")
    print(f"  output: {args.output}")
    print(f"  classes: {len(stats.classes)}")
    print(f"  skipped objects: {stats.skipped_objects}")
    for split in SPLITS:
        print(
            f"  {split}: images={stats.images[split]}, "
            f"labels={stats.labels[split]}, objects={stats.objects[split]}"
        )
    print(f"  data yaml: {args.output / 'data.yaml'}")


if __name__ == "__main__":
    main()
