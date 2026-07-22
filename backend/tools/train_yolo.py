"""
Train an Ultralytics YOLO model with a prepared YOLO-format dataset.

Typical flow:
    python tools/prepare_tt100k.py --annotations D:/datasets/TT100K/annotations_all.json \
        --image-root D:/datasets/TT100K --output datasets/tt100k

    python tools/train_yolo.py --data datasets/tt100k/data.yaml --dry-run
    python tools/train_yolo.py --data datasets/tt100k/data.yaml --epochs 50 --device cpu
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


IMAGE_SUFFIXES = {".bmp", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}


@dataclass(frozen=True)
class SplitSummary:
    name: str
    image_dir: Path
    label_dir: Path
    images: int
    labels: int


def _resolve_split_path(dataset_root: Path, split_value: Any) -> Path:
    if isinstance(split_value, list):
        if not split_value:
            raise ValueError("split path list is empty")
        split_value = split_value[0]

    if not isinstance(split_value, str):
        raise ValueError(f"split path must be a string, got {type(split_value).__name__}")

    split_path = Path(split_value)
    if not split_path.is_absolute():
        split_path = dataset_root / split_path
    return split_path


def _infer_label_dir(dataset_root: Path, image_dir: Path) -> Path:
    try:
        relative = image_dir.resolve().relative_to(dataset_root.resolve())
    except ValueError:
        return image_dir.parent.parent / "labels" / image_dir.name

    parts = list(relative.parts)
    if parts and parts[0] == "images":
        parts[0] = "labels"
        return dataset_root.joinpath(*parts)
    return dataset_root / "labels" / image_dir.name


def _count_images(image_dir: Path) -> int:
    return sum(1 for path in image_dir.rglob("*") if path.suffix.lower() in IMAGE_SUFFIXES)


def validate_yolo_dataset(data_yaml: Path) -> list[SplitSummary]:
    data_yaml = data_yaml.resolve()
    if not data_yaml.exists():
        raise FileNotFoundError(f"data.yaml not found: {data_yaml}")

    config = yaml.safe_load(data_yaml.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError(f"Invalid data.yaml: {data_yaml}")

    dataset_root_value = config.get("path", ".")
    dataset_root = Path(dataset_root_value)
    if not dataset_root.is_absolute():
        dataset_root = data_yaml.parent / dataset_root
    dataset_root = dataset_root.resolve()

    summaries: list[SplitSummary] = []
    for split_name in ("train", "val"):
        if split_name not in config:
            raise ValueError(f"data.yaml missing required split: {split_name}")

        image_dir = _resolve_split_path(dataset_root, config[split_name])
        label_dir = _infer_label_dir(dataset_root, image_dir)
        if not image_dir.exists():
            raise FileNotFoundError(f"{split_name} image directory not found: {image_dir}")
        if not label_dir.exists():
            raise FileNotFoundError(f"{split_name} label directory not found: {label_dir}")

        image_count = _count_images(image_dir)
        label_count = sum(1 for path in label_dir.rglob("*.txt"))
        if image_count == 0:
            raise ValueError(f"{split_name} split has no images: {image_dir}")
        if label_count == 0:
            raise ValueError(f"{split_name} split has no label files: {label_dir}")

        summaries.append(
            SplitSummary(
                name=split_name,
                image_dir=image_dir,
                label_dir=label_dir,
                images=image_count,
                labels=label_count,
            )
        )

    return summaries


def write_ultralytics_data_yaml(data_yaml: Path) -> Path:
    data_yaml = data_yaml.resolve()
    config = yaml.safe_load(data_yaml.read_text(encoding="utf-8"))
    dataset_root = Path(config.get("path", "."))
    if not dataset_root.is_absolute():
        dataset_root = data_yaml.parent / dataset_root

    config["path"] = dataset_root.resolve().as_posix()
    output_yaml = data_yaml.with_name("data.ultralytics.yaml")
    output_yaml.write_text(
        yaml.safe_dump(config, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )
    return output_yaml


def train(args: argparse.Namespace) -> Path | None:
    summaries = validate_yolo_dataset(args.data)

    print("YOLO dataset is ready")
    for summary in summaries:
        print(
            f"  {summary.name}: {summary.images} images, {summary.labels} labels "
            f"({summary.image_dir})"
        )

    if args.dry_run:
        print("Dry run only; training was not started.")
        return None

    from ultralytics import YOLO

    train_data_yaml = write_ultralytics_data_yaml(args.data)
    model = YOLO(args.model)
    result = model.train(
        data=str(train_data_yaml),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        workers=args.workers,
        project=str(args.project),
        name=args.name,
        exist_ok=args.exist_ok,
        cache=args.cache,
        patience=args.patience,
        fraction=args.fraction,
        resume=args.resume,
        optimizer=args.optimizer,
        lr0=args.lr0,
        momentum=args.momentum,
    )
    save_dir = Path(result.save_dir)
    print(f"Training finished: {save_dir}")
    return save_dir


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Train a YOLO model for traffic objects.")
    parser.add_argument("--data", required=True, type=Path, help="Path to YOLO data.yaml")
    parser.add_argument("--model", default="yolo11n.pt", help="Base model path or name")
    parser.add_argument("--epochs", default=50, type=int, help="Training epochs")
    parser.add_argument("--imgsz", default=640, type=int, help="Training image size")
    parser.add_argument("--batch", default=8, type=int, help="Batch size")
    parser.add_argument("--device", default="0", help="cpu or CUDA device index, for example 0")
    parser.add_argument("--workers", default=2, type=int, help="Data loader workers")
    parser.add_argument("--project", default=Path("runs/train"), type=Path, help="Output directory")
    parser.add_argument("--name", default="traffic_tt100k_yolo11n", help="Run name")
    parser.add_argument("--patience", default=20, type=int, help="Early stopping patience")
    parser.add_argument("--optimizer", default="auto", help="Optimizer name, for example SGD or AdamW")
    parser.add_argument("--lr0", default=0.01, type=float, help="Initial learning rate")
    parser.add_argument("--momentum", default=0.937, type=float, help="SGD momentum or Adam beta1")
    parser.add_argument("--cache", action="store_true", help="Cache images for faster training")
    parser.add_argument("--fraction", default=1.0, type=float, help="Dataset fraction used for training")
    parser.add_argument("--resume", action="store_true", help="Resume training from the model checkpoint")
    parser.add_argument("--exist-ok", action="store_true", help="Overwrite an existing run name")
    parser.add_argument("--dry-run", action="store_true", help="Validate data without training")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        train(args)
    except (FileNotFoundError, ValueError) as exc:
        parser.exit(2, f"error: {exc}\n")


if __name__ == "__main__":
    main()
