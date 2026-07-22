"""Train an Ultralytics classification model on prepared GTSRB data."""

from __future__ import annotations

import argparse
from pathlib import Path


IMAGE_SUFFIXES = {".bmp", ".jpeg", ".jpg", ".png", ".ppm", ".webp"}
CLASS_NAMES = tuple(f"{class_id:02d}" for class_id in range(43))


def validate_classification_dataset(path: Path) -> dict[str, int]:
    path = Path(path).resolve()
    if not path.is_dir():
        raise FileNotFoundError(f"Classification dataset not found: {path}")
    counts = {}
    for split in ("train", "val"):
        split_dir = path / split
        if not split_dir.is_dir():
            raise FileNotFoundError(f"{split} split not found: {split_dir}")
        total = 0
        for class_name in CLASS_NAMES:
            class_dir = split_dir / class_name
            if not class_dir.is_dir():
                raise FileNotFoundError(f"{split} class directory not found: {class_dir}")
            total += sum(
                1
                for image in class_dir.iterdir()
                if image.is_file() and image.suffix.lower() in IMAGE_SUFFIXES
            )
        if total == 0:
            raise ValueError(f"{split} split contains no images: {split_dir}")
        counts[split] = total
    return counts


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Train a GTSRB classifier")
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--model", default="yolo11n-cls.pt")
    parser.add_argument("--epochs", default=50, type=int)
    parser.add_argument("--imgsz", default=128, type=int)
    parser.add_argument("--batch", default=128, type=int)
    parser.add_argument("--device", default="0")
    parser.add_argument("--workers", default=2, type=int)
    parser.add_argument("--project", default=Path("training/runs"), type=Path)
    parser.add_argument("--name", default="gtsrb_yolo11n_cls_gpu")
    parser.add_argument("--patience", default=12, type=int)
    parser.add_argument("--exist-ok", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def train(args: argparse.Namespace) -> Path | None:
    counts = validate_classification_dataset(args.data)
    print(f"GTSRB dataset is ready: train={counts['train']} val={counts['val']}")
    if args.dry_run:
        print("Dry run only; training was not started.")
        return None

    from ultralytics import YOLO

    model = YOLO(args.model)
    result = model.train(
        data=str(Path(args.data).resolve()),
        task="classify",
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        workers=args.workers,
        project=str(Path(args.project).resolve()),
        name=args.name,
        exist_ok=args.exist_ok,
        patience=args.patience,
    )
    save_dir = Path(result.save_dir)
    print(f"Training finished: {save_dir}")
    return save_dir


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        train(args)
    except (FileNotFoundError, ValueError) as exc:
        parser.exit(2, f"error: {exc}\n")


if __name__ == "__main__":
    main()
