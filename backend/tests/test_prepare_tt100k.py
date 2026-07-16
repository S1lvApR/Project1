import importlib.util
import json
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "prepare_tt100k.py"
SPEC = importlib.util.spec_from_file_location("prepare_tt100k", MODULE_PATH)
prepare_tt100k = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = prepare_tt100k
SPEC.loader.exec_module(prepare_tt100k)


def test_split_records_maps_tt100k_other_to_validation():
    records = [
        {"path": "train/a.jpg"},
        {"path": "other/b.jpg"},
        {"path": "test/c.jpg"},
    ]

    splits = prepare_tt100k.split_records(
        records,
        val_ratio=0.0,
        test_ratio=0.0,
        seed=42,
    )

    assert [item["path"] for item in splits["train"]] == ["train/a.jpg"]
    assert [item["path"] for item in splits["val"]] == ["other/b.jpg"]
    assert [item["path"] for item in splits["test"]] == ["test/c.jpg"]


def test_convert_tt100k_generates_yolo_dataset(tmp_path):
    raw_dir = tmp_path / "raw"
    (raw_dir / "data" / "train").mkdir(parents=True)
    (raw_dir / "data" / "valid").mkdir(parents=True)
    (raw_dir / "data" / "train" / "sign_a.jpg").write_bytes(b"fake image")
    (raw_dir / "data" / "valid" / "sign_b.jpg").write_bytes(b"fake image")

    annotations = {
        "imgs": {
            "a": {
                "path": "train/sign_a.jpg",
                "width": 100,
                "height": 50,
                "objects": [
                    {
                        "category": "pl80",
                        "bbox": {"xmin": 10, "ymin": 5, "xmax": 50, "ymax": 25},
                    }
                ],
            },
            "b": {
                "path": "valid/sign_b.jpg",
                "width": 200,
                "height": 100,
                "objects": [
                    {
                        "category": "p5",
                        "bbox": {"xmin": 50, "ymin": 20, "xmax": 150, "ymax": 60},
                    }
                ],
            },
        }
    }
    annotation_path = raw_dir / "annotations_all.json"
    annotation_path.write_text(json.dumps(annotations), encoding="utf-8")

    output_dir = tmp_path / "yolo"
    stats = prepare_tt100k.convert_dataset(
        annotation_path=annotation_path,
        image_root=raw_dir,
        output_dir=output_dir,
        image_mode="copy",
    )

    assert stats.images == {"train": 1, "val": 1, "test": 0}
    assert stats.labels == {"train": 1, "val": 1, "test": 0}
    assert stats.objects == {"train": 1, "val": 1, "test": 0}

    data_yaml = (output_dir / "data.yaml").read_text(encoding="utf-8")
    assert "path: ." in data_yaml
    assert "train: images/train" in data_yaml
    assert "val: images/val" in data_yaml
    assert "nc: 2" in data_yaml
    assert '0: "p5"' in data_yaml
    assert '1: "pl80"' in data_yaml

    label = (output_dir / "labels" / "train" / "train__sign_a.txt").read_text(
        encoding="utf-8"
    )
    assert label == "1 0.300000 0.300000 0.400000 0.400000\n"
    assert (output_dir / "images" / "train" / "train__sign_a.jpg").exists()


def test_min_instances_filters_rare_classes(tmp_path):
    raw_dir = tmp_path / "raw"
    (raw_dir / "train").mkdir(parents=True)
    (raw_dir / "train" / "sign.jpg").write_bytes(b"fake image")

    annotations = {
        "imgs": {
            "a": {
                "path": "train/sign.jpg",
                "width": 100,
                "height": 100,
                "objects": [
                    {"category": "common", "bbox": [0, 0, 10, 10]},
                    {"category": "common", "bbox": [10, 10, 20, 20]},
                    {"category": "rare", "bbox": [20, 20, 30, 30]},
                ],
            }
        }
    }
    annotation_path = raw_dir / "annotations_all.json"
    annotation_path.write_text(json.dumps(annotations), encoding="utf-8")

    output_dir = tmp_path / "yolo"
    stats = prepare_tt100k.convert_dataset(
        annotation_path=annotation_path,
        image_root=raw_dir,
        output_dir=output_dir,
        min_instances=2,
        image_mode="none",
    )

    assert stats.classes == ["common"]
    assert stats.skipped_objects == 1
    label = next((output_dir / "labels").glob("**/*.txt")).read_text(encoding="utf-8")
    assert label.count("\n") == 2


def test_explicit_class_names_do_not_leak_from_validation(tmp_path):
    raw_dir = tmp_path / "raw"
    (raw_dir / "train").mkdir(parents=True)
    (raw_dir / "other").mkdir(parents=True)
    (raw_dir / "train" / "train.jpg").write_bytes(b"fake image")
    (raw_dir / "other" / "validation.jpg").write_bytes(b"fake image")
    annotations = {
        "imgs": {
            "train": {
                "path": "train/train.jpg",
                "width": 100,
                "height": 100,
                "objects": [
                    {"category": "common", "bbox": [10, 10, 30, 30]},
                ],
            },
            "validation": {
                "path": "other/validation.jpg",
                "width": 100,
                "height": 100,
                "objects": [
                    {"category": "validation_only", "bbox": [10, 10, 30, 30]},
                ],
            },
        }
    }
    annotation_path = raw_dir / "annotations.json"
    annotation_path.write_text(json.dumps(annotations), encoding="utf-8")

    output_dir = tmp_path / "yolo"
    stats = prepare_tt100k.convert_dataset(
        annotation_path=annotation_path,
        image_root=raw_dir,
        output_dir=output_dir,
        class_names=["common"],
        image_mode="none",
    )

    assert stats.classes == ["common"]
    assert stats.skipped_objects == 1
    data_yaml = (output_dir / "data.yaml").read_text(encoding="utf-8")
    assert '0: "common"' in data_yaml
    assert "validation_only" not in data_yaml


def test_parse_args_accepts_common_45(monkeypatch, tmp_path):
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "prepare_tt100k.py",
            "--annotations",
            str(tmp_path / "annotations.json"),
            "--image-root",
            str(tmp_path),
            "--common-45",
        ],
    )

    args = prepare_tt100k.parse_args()

    assert args.common_45 is True
