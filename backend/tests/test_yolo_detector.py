from io import BytesIO

import numpy as np
import pytest
from PIL import Image

from app.services.yolo_detector import (
    InvalidImageError,
    LocalYoloDetector,
    ModelUnavailableError,
)
from app.services.tt100k_labels import (
    TT100K_COMMON_45_CLASSES,
    build_tt100k_class_id_map,
)


class FakeTensor:
    def __init__(self, value):
        self.value = value

    def cpu(self):
        return self

    def tolist(self):
        return self.value


class FakeBoxes:
    xyxy = FakeTensor([[1.0, 2.0, 20.0, 22.0]])
    conf = FakeTensor([0.91])
    cls = FakeTensor([1.0])


class FakeResult:
    boxes = FakeBoxes()
    names = {0: "p10", 1: "pl60"}
    speed = {"inference": 12.5}
    orig_shape = (24, 32)

    @staticmethod
    def plot():
        return np.zeros((24, 32, 3), dtype=np.uint8)


class FakeModel:
    names = FakeResult.names

    def __init__(self):
        self.calls = []

    def predict(self, **kwargs):
        self.calls.append(kwargs)
        return [FakeResult()]


class FakeSahiBbox:
    @staticmethod
    def to_xyxy():
        return [3.0, 4.0, 21.0, 23.0]


class FakeSahiScore:
    value = 0.93


class FakeSahiCategory:
    id = 1
    name = "pl60"


class FakeSahiObjectPrediction:
    bbox = FakeSahiBbox()
    score = FakeSahiScore()
    category = FakeSahiCategory()


class FakeSahiPredictionResult:
    object_prediction_list = [FakeSahiObjectPrediction()]
    durations_in_seconds = {"prediction": 0.125}


class FakeSahiModel:
    def __init__(self):
        self.model = FakeModel()
        self.confidence_threshold = None
        self.image_size = None


def make_jpeg(width=32, height=24):
    output = BytesIO()
    Image.new("RGB", (width, height), color="white").save(output, format="JPEG")
    return output.getvalue()


def test_detector_prefers_gpu_and_converts_ultralytics_result(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    loaded_paths = []
    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        model_factory=lambda path: loaded_paths.append(path) or model,
        cuda_available=lambda: True,
    )

    prediction = detector.predict(
        make_jpeg(),
        confidence=0.3,
        iou=0.5,
        image_size=640,
    )

    assert detector.selected_device == "0"
    assert loaded_paths == [str(model_path)]
    assert prediction.width == 32
    assert prediction.height == 24
    assert prediction.inference_time_ms == 12.5
    assert prediction.detections[0].class_id == 1
    assert prediction.detections[0].class_name == "pl60"
    assert prediction.detections[0].confidence == pytest.approx(0.91)
    assert prediction.detections[0].bbox == (1.0, 2.0, 20.0, 22.0)
    assert prediction.annotated_jpeg.startswith(b"\xff\xd8")
    assert len(model.calls) == 1
    call = model.calls[0]
    assert call["source"].size == (32, 24)
    assert {
        key: call[key]
        for key in ("conf", "iou", "imgsz", "device", "verbose")
    } == {
        "conf": 0.3,
        "iou": 0.5,
        "imgsz": 640,
        "device": "0",
        "verbose": False,
    }


def test_detector_auto_falls_back_to_cpu(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        model_factory=lambda _path: FakeModel(),
        cuda_available=lambda: False,
    )

    assert detector.selected_device == "cpu"


def test_detector_maps_explicit_gpu_mode_to_ultralytics_device_zero(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    detector = LocalYoloDetector(
        model_path=model_path,
        device="gpu",
        model_factory=lambda _path: model,
        cuda_available=lambda: True,
    )

    detector.predict(make_jpeg())

    assert detector.selected_device == "0"
    assert model.calls[0]["device"] == "0"


def test_detector_exposes_checkpoint_class_names_lazily(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    detector = LocalYoloDetector(
        model_path=model_path,
        model_factory=lambda _path: model,
    )

    assert detector.class_names == {0: "p10", 1: "pl60"}


def test_detector_rejects_missing_checkpoint_before_loading(tmp_path):
    factory_called = False

    def model_factory(_path):
        nonlocal factory_called
        factory_called = True
        return FakeModel()

    detector = LocalYoloDetector(
        model_path=tmp_path / "missing.pt",
        model_factory=model_factory,
    )

    with pytest.raises(ModelUnavailableError, match="checkpoint does not exist"):
        detector.predict(make_jpeg())

    assert factory_called is False


def test_detector_rejects_corrupt_image_without_running_model(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    detector = LocalYoloDetector(
        model_path=model_path,
        model_factory=lambda _path: model,
    )

    with pytest.raises(InvalidImageError, match="decode"):
        detector.predict(b"not-an-image")

    assert model.calls == []


def test_reference_42_class_names_map_to_canonical_45_ids():
    reference_names = (
        "i2", "i4", "i5", "il100", "i160", "il80", "io", "ip",
        "p10", "p11", "p12", "p19", "p23", "p26", "p27", "p3",
        "p5", "p\u00f3", "pg", "ph4", "ph4.5", "pl100", "pl120",
        "pl20", "pl30", "pl40", "pl5", "pl50", "pl60", "pl70",
        "pL80", "pm20", "pm30", "pm55", "pn", "pne", "po",
        "pr40", "w13", "w55", "w57", "w59",
    )

    mapping = build_tt100k_class_id_map(dict(enumerate(reference_names)))

    assert mapping[4] == 4
    assert mapping[17] == 17
    assert mapping[21] == 22
    assert mapping[28] == 29
    assert mapping[39] == 41
    assert mapping[41] == 43


def test_detector_canonicalizes_reference_model_predictions(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    native_names = {0: "p10", 1: "pl60"}
    result = FakeResult()
    result.names = native_names
    model = FakeModel()
    model.names = native_names
    model.predict = lambda **_kwargs: [result]
    detector = LocalYoloDetector(
        model_path=model_path,
        model_factory=lambda _path: model,
        canonicalize_tt100k_classes=True,
    )

    prediction = detector.predict(make_jpeg())

    assert len(detector.class_names) == 45
    assert detector.class_names[29] == "pl60"
    assert prediction.detections[0].class_id == 29
    assert prediction.detections[0].class_name == "pl60"
    assert tuple(detector.class_names.values()) == TT100K_COMMON_45_CLASSES


def test_detector_uses_sahi_for_sliced_canonical_predictions(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    sahi_model = FakeSahiModel()
    factory_calls = []
    prediction_calls = []

    def sahi_model_factory(**kwargs):
        factory_calls.append(kwargs)
        return sahi_model

    def sliced_predictor(**kwargs):
        prediction_calls.append(kwargs)
        return FakeSahiPredictionResult()

    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        cuda_available=lambda: True,
        canonicalize_tt100k_classes=True,
        use_sahi=True,
        sahi_slice_height=512,
        sahi_slice_width=512,
        sahi_overlap_ratio=0.2,
        sahi_model_image_size=640,
        sahi_model_factory=sahi_model_factory,
        sliced_predictor=sliced_predictor,
    )

    prediction = detector.predict(
        make_jpeg(width=64, height=48),
        confidence=0.5,
        image_size=1280,
    )

    assert factory_calls == [
        {
            "model_path": str(model_path),
            "device": "0",
            "confidence_threshold": 0.5,
            "image_size": 640,
        }
    ]
    assert prediction_calls[0]["slice_height"] == 512
    assert prediction_calls[0]["slice_width"] == 512
    assert prediction_calls[0]["overlap_height_ratio"] == 0.2
    assert prediction_calls[0]["overlap_width_ratio"] == 0.2
    assert prediction_calls[0]["perform_standard_pred"] is True
    assert prediction.width == 64
    assert prediction.height == 48
    assert prediction.inference_time_ms == pytest.approx(125.0)
    assert prediction.detections[0].class_id == 29
    assert prediction.detections[0].class_name == "pl60"
    assert prediction.annotated_jpeg.startswith(b"\xff\xd8")


def test_realtime_prediction_bypasses_sahi_and_can_force_cpu(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    sahi_model = FakeSahiModel()
    sliced_calls = []
    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        cuda_available=lambda: True,
        use_sahi=True,
        sahi_model_factory=lambda **_kwargs: sahi_model,
        sliced_predictor=lambda **kwargs: sliced_calls.append(kwargs),
    )

    prediction = detector.predict_realtime(
        make_jpeg(),
        confidence=0.4,
        iou=0.5,
        image_size=416,
        device="cpu",
    )

    assert sliced_calls == []
    assert prediction.detections[0].class_name == "pl60"
    assert len(sahi_model.model.calls) == 1
    assert sahi_model.model.calls[0]["device"] == "cpu"
    assert sahi_model.model.calls[0]["imgsz"] == 416


def test_video_frame_prediction_passes_bgr_array_directly_to_model(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        model_factory=lambda _path: model,
        cuda_available=lambda: True,
    )
    frame = np.zeros((24, 32, 3), dtype=np.uint8)

    prediction = detector.predict_video_frame(
        frame,
        confidence=0.5,
        iou=0.45,
        image_size=1280,
    )

    assert model.calls[0]["source"] is frame
    assert model.calls[0]["device"] == "0"
    assert model.calls[0]["imgsz"] == 1280
    assert prediction.width == 32
    assert prediction.height == 24
    assert prediction.inference_time_ms == 12.5
    assert prediction.detections[0].class_name == "pl60"
    assert not hasattr(prediction, "annotated_jpeg")


@pytest.mark.parametrize(
    "frame",
    [
        b"not-an-array",
        np.zeros((24, 32), dtype=np.uint8),
        np.zeros((24, 32, 4), dtype=np.uint8),
    ],
)
def test_video_frame_prediction_rejects_invalid_frames_before_loading_model(
    tmp_path,
    frame,
):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    loaded = []
    detector = LocalYoloDetector(
        model_path=model_path,
        model_factory=lambda path: loaded.append(path) or FakeModel(),
    )

    with pytest.raises(InvalidImageError, match="BGR"):
        detector.predict_video_frame(frame)

    assert loaded == []
