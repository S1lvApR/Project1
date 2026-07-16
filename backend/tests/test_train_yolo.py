import importlib.util
import sys
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "train_yolo.py"
SPEC = importlib.util.spec_from_file_location("train_yolo", MODULE_PATH)
train_yolo = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = train_yolo
SPEC.loader.exec_module(train_yolo)


def test_validate_yolo_dataset_accepts_prepared_dataset(tmp_path):
    dataset = tmp_path / "dataset"
    (dataset / "images" / "train").mkdir(parents=True)
    (dataset / "images" / "val").mkdir(parents=True)
    (dataset / "labels" / "train").mkdir(parents=True)
    (dataset / "labels" / "val").mkdir(parents=True)

    (dataset / "images" / "train" / "a.jpg").write_bytes(b"fake image")
    (dataset / "images" / "val" / "b.jpg").write_bytes(b"fake image")
    (dataset / "labels" / "train" / "a.txt").write_text(
        "0 0.5 0.5 0.1 0.1\n",
        encoding="utf-8",
    )
    (dataset / "labels" / "val" / "b.txt").write_text(
        "0 0.5 0.5 0.1 0.1\n",
        encoding="utf-8",
    )
    data_yaml = dataset / "data.yaml"
    data_yaml.write_text(
        "\n".join(
            [
                "path: .",
                "train: images/train",
                "val: images/val",
                "nc: 1",
                "names:",
                '  0: "traffic_sign"',
            ]
        ),
        encoding="utf-8",
    )

    summaries = train_yolo.validate_yolo_dataset(data_yaml)

    assert [(item.name, item.images, item.labels) for item in summaries] == [
        ("train", 1, 1),
        ("val", 1, 1),
    ]


def test_validate_yolo_dataset_rejects_missing_images(tmp_path):
    dataset = tmp_path / "dataset"
    (dataset / "labels" / "train").mkdir(parents=True)
    (dataset / "labels" / "val").mkdir(parents=True)
    data_yaml = dataset / "data.yaml"
    data_yaml.write_text(
        "\n".join(
            [
                "path: .",
                "train: images/train",
                "val: images/val",
                "nc: 1",
                "names:",
                '  0: "traffic_sign"',
            ]
        ),
        encoding="utf-8",
    )

    with pytest.raises(FileNotFoundError, match="train image directory"):
        train_yolo.validate_yolo_dataset(data_yaml)


def test_training_parser_exposes_optimizer_hyperparameters(monkeypatch, tmp_path):
    monkeypatch.setattr(
        sys,
        "argv",
        ["train_yolo.py", "--data", str(tmp_path / "data.yaml")],
    )

    args = train_yolo.build_parser().parse_args()

    assert args.optimizer == "auto"
    assert args.lr0 == 0.01
    assert args.momentum == 0.937
