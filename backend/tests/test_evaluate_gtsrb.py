import csv
import importlib.util
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "evaluate_gtsrb.py"
SPEC = importlib.util.spec_from_file_location("evaluate_gtsrb", MODULE_PATH)
evaluate_gtsrb = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = evaluate_gtsrb
SPEC.loader.exec_module(evaluate_gtsrb)


def write_truth(path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream, delimiter=";")
        writer.writerow(
            ["Filename", "Width", "Height", "Roi.X1", "Roi.Y1", "Roi.X2", "Roi.Y2", "ClassId"]
        )
        writer.writerow(["00000.ppm", 53, 54, 6, 5, 48, 49, 16])
        writer.writerow(["00006.ppm", 147, 130, 12, 12, 135, 119, 18])


def test_load_ground_truth_matches_png_images_by_stem(tmp_path):
    truth_path = tmp_path / "GT-final_test.csv"
    write_truth(truth_path)
    (tmp_path / "00000.png").write_bytes(b"image")
    (tmp_path / "00006.png").write_bytes(b"image")

    truth = evaluate_gtsrb.load_ground_truth(truth_path)
    samples = evaluate_gtsrb.match_test_images(tmp_path, truth)

    assert truth == {"00000": 16, "00006": 18}
    assert [(sample.path.name, sample.class_id) for sample in samples] == [
        ("00000.png", 16),
        ("00006.png", 18),
    ]


def test_compute_metrics_reports_accuracy_recall_and_confusion():
    rows = [
        evaluate_gtsrb.EvaluationRow("00000.png", 16, 16, 0.99),
        evaluate_gtsrb.EvaluationRow("00006.png", 18, 18, 0.98),
        evaluate_gtsrb.EvaluationRow("wrong.png", 18, 16, 0.55),
    ]

    metrics = evaluate_gtsrb.compute_metrics(rows, class_count=43)

    assert metrics["top1_accuracy"] == 2 / 3
    assert metrics["per_class_recall"][16] == 1.0
    assert metrics["per_class_recall"][18] == 0.5
    assert metrics["confusion_matrix"][18][16] == 1
    assert 0 in metrics["zero_recall_classes"]


def test_gtsrb_regression_labels_are_stable():
    assert evaluate_gtsrb.GTSRB_LABELS[16] == "Vehicles over 3.5 metric tons prohibited"
    assert evaluate_gtsrb.GTSRB_LABELS[18] == "General caution"


def test_write_reports_creates_metrics_predictions_and_confusion_files(tmp_path):
    rows = [
        evaluate_gtsrb.EvaluationRow("00000.png", 16, 16, 0.99),
        evaluate_gtsrb.EvaluationRow("00006.png", 18, 18, 0.98),
    ]
    metrics = evaluate_gtsrb.compute_metrics(rows, class_count=43)

    evaluate_gtsrb.write_reports(tmp_path / "report", rows, metrics)

    assert (tmp_path / "report" / "metrics.json").is_file()
    assert (tmp_path / "report" / "predictions.csv").is_file()
    assert (tmp_path / "report" / "confusion_matrix.csv").is_file()
