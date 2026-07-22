"""Evaluate a GTSRB classifier on the held-out project Test directory."""

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    from app.services.gtsrb_labels import GTSRB_LABELS
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from app.services.gtsrb_labels import GTSRB_LABELS


@dataclass(frozen=True)
class TestSample:
    path: Path
    class_id: int


@dataclass(frozen=True)
class EvaluationRow:
    filename: str
    truth: int
    predicted: int
    confidence: float


def load_ground_truth(_path):
    truth = {}
    with Path(_path).open("r", newline="", encoding="utf-8-sig") as stream:
        for row in csv.DictReader(stream, delimiter=";"):
            filename = row.get("Filename")
            class_id = row.get("ClassId")
            if not filename or class_id is None:
                raise ValueError("Ground-truth CSV requires Filename and ClassId columns")
            truth[Path(filename).stem] = int(class_id)
    if not truth:
        raise ValueError("Ground-truth CSV contains no rows")
    return truth


def match_test_images(_test_dir, _truth):
    test_dir = Path(_test_dir)
    truth = dict(_truth)
    samples = []
    for path in sorted(test_dir.iterdir()):
        if not path.is_file() or path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".ppm"}:
            continue
        stem = path.stem
        if stem not in truth:
            raise ValueError(f"Missing ground truth for test image: {path.name}")
        samples.append(TestSample(path=path, class_id=truth.pop(stem)))
    if truth:
        raise ValueError(f"Ground truth has no matching test image: {next(iter(truth))}")
    if not samples:
        raise ValueError(f"No test images found in {test_dir}")
    return samples


def compute_metrics(_rows, class_count=43):
    rows = list(_rows)
    if not rows:
        raise ValueError("Cannot compute metrics for an empty prediction list")
    correct = sum(row.truth == row.predicted for row in rows)
    confusion = [[0 for _ in range(class_count)] for _ in range(class_count)]
    per_class_recall = {}
    for row in rows:
        if not 0 <= row.truth < class_count or not 0 <= row.predicted < class_count:
            raise ValueError(f"Class ID outside 0..{class_count - 1}: {row}")
        confusion[row.truth][row.predicted] += 1
    for class_id in range(class_count):
        actual = sum(confusion[class_id])
        per_class_recall[class_id] = (
            confusion[class_id][class_id] / actual if actual else 0.0
        )
    return {
        "sample_count": len(rows),
        "top1_accuracy": correct / len(rows),
        "per_class_recall": per_class_recall,
        "macro_recall": sum(per_class_recall.values()) / class_count,
        "zero_recall_classes": [
            class_id for class_id, recall in per_class_recall.items() if recall == 0.0
        ],
        "confusion_matrix": confusion,
    }


def _scalar(value):
    return value.item() if hasattr(value, "item") else value


def predict_samples(model, samples, image_size=128, batch_size=256, device="0"):
    rows = []
    samples = list(samples)
    for start in range(0, len(samples), batch_size):
        batch = samples[start : start + batch_size]
        results = model.predict(
            source=[str(sample.path) for sample in batch],
            imgsz=image_size,
            batch=len(batch),
            device=device,
            verbose=False,
        )
        if len(results) != len(batch):
            raise RuntimeError(
                f"Classifier returned {len(results)} results for {len(batch)} images"
            )
        for sample, result in zip(batch, results):
            probabilities = getattr(result, "probs", None)
            if probabilities is None:
                raise RuntimeError(
                    f"Classifier returned no probabilities for {sample.path.name}"
                )
            rows.append(
                EvaluationRow(
                    filename=sample.path.name,
                    truth=sample.class_id,
                    predicted=int(_scalar(probabilities.top1)),
                    confidence=float(_scalar(probabilities.top1conf)),
                )
            )
    return rows


def evaluate_checkpoint(
    model_path: Path,
    test_dir: Path,
    ground_truth: Path,
    image_size: int = 128,
    batch_size: int = 256,
    device: str = "0",
):
    from ultralytics import YOLO

    samples = match_test_images(test_dir, load_ground_truth(ground_truth))
    model = YOLO(str(model_path))
    rows = predict_samples(
        model,
        samples,
        image_size=image_size,
        batch_size=batch_size,
        device=device,
    )
    return rows, compute_metrics(rows, class_count=len(GTSRB_LABELS))


def write_reports(output_dir: Path, rows, metrics):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    metrics_payload = dict(metrics)
    metrics_payload["class_names"] = list(GTSRB_LABELS)
    (output_dir / "metrics.json").write_text(
        json.dumps(metrics_payload, indent=2),
        encoding="utf-8",
    )
    with (output_dir / "predictions.csv").open(
        "w", newline="", encoding="utf-8"
    ) as stream:
        writer = csv.writer(stream)
        writer.writerow(["filename", "truth", "predicted", "confidence", "correct"])
        for row in rows:
            writer.writerow(
                [
                    row.filename,
                    row.truth,
                    row.predicted,
                    row.confidence,
                    row.truth == row.predicted,
                ]
            )
    with (output_dir / "confusion_matrix.csv").open(
        "w", newline="", encoding="utf-8"
    ) as stream:
        writer = csv.writer(stream)
        writer.writerow(["truth/predicted", *range(len(GTSRB_LABELS))])
        for class_id, values in enumerate(metrics["confusion_matrix"]):
            writer.writerow([class_id, *values])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate a GTSRB classifier")
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--test-dir", type=Path, default=Path("Test"))
    parser.add_argument("--ground-truth", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--imgsz", type=int, default=128)
    parser.add_argument("--batch", type=int, default=256)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    rows, metrics = evaluate_checkpoint(
        model_path=args.model,
        test_dir=args.test_dir,
        ground_truth=args.ground_truth,
        image_size=args.imgsz,
        batch_size=args.batch,
        device=args.device,
    )
    write_reports(args.output, rows, metrics)
    print(f"top1_accuracy={metrics['top1_accuracy']:.6f}")
    print(f"macro_recall={metrics['macro_recall']:.6f}")
    print(f"zero_recall_classes={metrics['zero_recall_classes']}")
    for filename in ("00000.png", "00006.png"):
        row = next((item for item in rows if item.filename == filename), None)
        if row:
            print(f"{filename}: predicted={row.predicted} confidence={row.confidence:.6f}")


if __name__ == "__main__":
    main()
