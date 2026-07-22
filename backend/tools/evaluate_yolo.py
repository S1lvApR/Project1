"""Evaluate a YOLO detector and save comparable metrics."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Evaluate a YOLO detector")
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--imgsz", type=int, default=1280)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--device", default="0")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--project", type=Path, default=Path("training/runs"))
    parser.add_argument("--name", default="tt100k_eval")
    return parser


def evaluate(args: argparse.Namespace) -> dict[str, float]:
    if not args.model.is_file():
        raise FileNotFoundError(f"YOLO checkpoint not found: {args.model}")
    if not args.data.is_file():
        raise FileNotFoundError(f"YOLO data YAML not found: {args.data}")

    from ultralytics import YOLO

    model = YOLO(str(args.model))
    result = model.val(
        data=str(args.data),
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        workers=args.workers,
        project=str(args.project),
        name=args.name,
        exist_ok=True,
        verbose=False,
    )
    metrics = {
        key: float(value)
        for key, value in result.results_dict.items()
        if isinstance(value, (int, float))
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    return metrics


def main() -> None:
    args = build_parser().parse_args()
    metrics = evaluate(args)
    for key, value in metrics.items():
        print(f"{key}={value:.6f}")


if __name__ == "__main__":
    main()
