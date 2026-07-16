from io import BytesIO

import pytest
from PIL import Image

from app.services.gtsrb_classifier import LocalSignClassifier
from app.services.yolo_detector import InvalidImageError, ModelUnavailableError


class FakeScalar:
    def __init__(self, value):
        self.value = value

    def item(self):
        return self.value


class FakeProbabilities:
    top1 = FakeScalar(16)
    top1conf = FakeScalar(0.975)


class FakeResult:
    probs = FakeProbabilities()
    speed = {"inference": 4.5}


class FakeModel:
    def __init__(self):
        self.calls = []

    def predict(self, **kwargs):
        self.calls.append(kwargs)
        return [FakeResult()]


def make_jpeg(width=53, height=54):
    output = BytesIO()
    Image.new("RGB", (width, height), color="white").save(output, format="JPEG")
    return output.getvalue()


def test_classifier_prefers_gpu_and_converts_top1_result(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    classifier = LocalSignClassifier(
        model_path=model_path,
        device="auto",
        model_factory=lambda _path: model,
        cuda_available=lambda: True,
    )

    prediction = classifier.predict(make_jpeg(), image_size=128)

    assert classifier.selected_device == "0"
    assert prediction.width == 53
    assert prediction.height == 54
    assert prediction.inference_time_ms == 4.5
    assert prediction.detections[0].class_id == 16
    assert (
        prediction.detections[0].class_name
        == "Vehicles over 3.5 metric tons prohibited"
    )
    assert prediction.detections[0].confidence == pytest.approx(0.975)
    assert prediction.detections[0].bbox == (0.0, 0.0, 53.0, 54.0)
    assert prediction.annotated_jpeg.startswith(b"\xff\xd8")
    assert classifier.class_names[18] == "General caution"
    assert model.calls[0]["source"].size == (53, 54)
    assert model.calls[0]["imgsz"] == 128
    assert model.calls[0]["device"] == "0"
    assert model.calls[0]["verbose"] is False


def test_classifier_auto_falls_back_to_cpu(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    classifier = LocalSignClassifier(
        model_path=model_path,
        device="auto",
        model_factory=lambda _path: FakeModel(),
        cuda_available=lambda: False,
    )

    assert classifier.selected_device == "cpu"


def test_classifier_maps_explicit_gpu_mode_to_ultralytics_device_zero(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    classifier = LocalSignClassifier(
        model_path=model_path,
        device="gpu",
        model_factory=lambda _path: model,
        cuda_available=lambda: True,
    )

    classifier.predict(make_jpeg())

    assert classifier.selected_device == "0"
    assert model.calls[0]["device"] == "0"


def test_classifier_rejects_missing_checkpoint(tmp_path):
    classifier = LocalSignClassifier(
        model_path=tmp_path / "missing.pt",
        model_factory=lambda _path: FakeModel(),
    )

    with pytest.raises(ModelUnavailableError, match="checkpoint does not exist"):
        classifier.predict(make_jpeg())


def test_classifier_rejects_corrupt_image_without_running_model(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    classifier = LocalSignClassifier(
        model_path=model_path,
        model_factory=lambda _path: model,
    )

    with pytest.raises(InvalidImageError, match="decode"):
        classifier.predict(b"not-an-image")

    assert model.calls == []
