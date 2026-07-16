import importlib.util
import hashlib
from io import BytesIO
import sys
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "prepare_gtsrb.py"
SPEC = importlib.util.spec_from_file_location("prepare_gtsrb", MODULE_PATH)
prepare_gtsrb = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = prepare_gtsrb
SPEC.loader.exec_module(prepare_gtsrb)


def make_training_tree(root: Path, class_directory_format: str = "{class_id:05d}") -> Path:
    training_root = root / "GTSRB" / "Training"
    for class_id in range(43):
        class_dir = training_root / class_directory_format.format(class_id=class_id)
        class_dir.mkdir(parents=True)
        for track_id in range(2):
            for frame_id in range(2):
                filename = f"{track_id:05d}_{frame_id:05d}.ppm"
                (class_dir / filename).write_bytes(b"fake ppm")
    return root


def track_keys(directory: Path) -> set[str]:
    return {path.stem.rsplit("_", 1)[0] for path in directory.glob("*.ppm")}


def test_prepare_dataset_keeps_tracks_in_one_split(tmp_path):
    source = make_training_tree(tmp_path / "source")
    output = tmp_path / "prepared"

    stats = prepare_gtsrb.prepare_dataset(
        source_dir=source,
        output_dir=output,
        val_ratio=0.5,
        seed=7,
        image_mode="copy",
        test_dir=tmp_path / "Test",
    )

    assert stats.classes == tuple(f"{class_id:02d}" for class_id in range(43))
    assert stats.train_images == 86
    assert stats.val_images == 86
    for class_id in range(43):
        class_name = f"{class_id:02d}"
        train_tracks = track_keys(output / "train" / class_name)
        val_tracks = track_keys(output / "val" / class_name)
        assert train_tracks
        assert val_tracks
        assert train_tracks.isdisjoint(val_tracks)


def test_prepare_dataset_rejects_output_inside_test_directory(tmp_path):
    source = make_training_tree(tmp_path / "source")
    test_dir = tmp_path / "Test"

    with pytest.raises(ValueError, match="held-out Test"):
        prepare_gtsrb.prepare_dataset(
            source_dir=source,
            output_dir=test_dir / "prepared",
            val_ratio=0.2,
            seed=42,
            image_mode="copy",
            test_dir=test_dir,
        )


def test_prepare_dataset_accepts_unpadded_numeric_class_directories(tmp_path):
    source = make_training_tree(
        tmp_path / "source",
        class_directory_format="{class_id}",
    )

    stats = prepare_gtsrb.prepare_dataset(
        source_dir=source / "GTSRB" / "Training",
        output_dir=tmp_path / "prepared",
        val_ratio=0.5,
        seed=7,
        image_mode="copy",
        test_dir=tmp_path / "Test",
    )

    assert stats.train_images + stats.val_images == 172


def test_download_archive_requires_matching_md5(tmp_path):
    payload = b"verified archive bytes"
    destination = tmp_path / "gtsrb.zip"

    prepare_gtsrb.download_archive(
        url="https://example.test/gtsrb.zip",
        destination=destination,
        expected_md5=hashlib.md5(payload).hexdigest(),
        opener=lambda _url: BytesIO(payload),
    )

    assert destination.read_bytes() == payload

    invalid_destination = tmp_path / "invalid.zip"
    with pytest.raises(ValueError, match="MD5"):
        prepare_gtsrb.download_archive(
            url="https://example.test/gtsrb.zip",
            destination=invalid_destination,
            expected_md5="0" * 32,
            opener=lambda _url: BytesIO(payload),
        )
    assert not invalid_destination.exists()


def test_parse_args_supports_verified_download(monkeypatch, tmp_path):
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "prepare_gtsrb.py",
            "--download",
            "--raw-root",
            str(tmp_path / "raw"),
            "--output",
            str(tmp_path / "prepared"),
        ],
    )

    args = prepare_gtsrb.parse_args()

    assert args.download is True
    assert args.raw_root == tmp_path / "raw"
    assert args.output == tmp_path / "prepared"
    assert args.image_mode == "hardlink"
