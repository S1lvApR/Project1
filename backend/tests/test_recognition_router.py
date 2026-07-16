from io import BytesIO
from pathlib import Path

from PIL import Image

from app.services.recognition_router import LocalRecognitionRouter
from app.services.yolo_detector import DetectedObject, ImagePrediction


def make_jpeg(width: int, height: int) -> bytes:
    output = BytesIO()
    Image.new("RGB", (width, height), color="white").save(output, format="JPEG")
    return output.getvalue()


class FakePredictor:
    def __init__(self, name: str):
        self.name = name
        self.calls = []
        self.model_path = Path(f"D:/models/{name}.pt")
        self.selected_device = "0"
        self.class_names = {0: name}

    def predict(self, image_bytes, confidence, iou, image_size):
        self.calls.append(
            {
                "image_bytes": image_bytes,
                "confidence": confidence,
                "iou": iou,
                "image_size": image_size,
            }
        )
        with Image.open(BytesIO(image_bytes)) as image:
            width, height = image.size
        return ImagePrediction(
            width=width,
            height=height,
            inference_time_ms=1.0,
            detections=(
                DetectedObject(
                    class_id=0,
                    class_name=self.name,
                    confidence=0.9,
                    bbox=(0.0, 0.0, float(width), float(height)),
                ),
            ),
            annotated_jpeg=b"jpeg",
        )


def make_router():
    detector = FakePredictor("tt100k")
    classifier = FakePredictor("gtsrb")
    return (
        LocalRecognitionRouter(
            detector=detector,
            classifier=classifier,
            crop_max_dimension=512,
            classification_image_size=128,
        ),
        detector,
        classifier,
    )


def test_auto_routes_compact_image_to_classifier():
    router, detector, classifier = make_router()

    prediction = router.predict(
        make_jpeg(53, 54),
        mode="auto",
        confidence=0.25,
        iou=0.45,
        image_size=1280,
    )

    assert not detector.calls
    assert classifier.calls[0]["image_size"] == 128
    assert prediction.recognition_mode == "classify"
    assert prediction.model_family == "gtsrb-classifier"
    assert prediction.dataset == "gtsrb"
    assert prediction.result_type == "classification"


def test_auto_routes_large_image_to_detector():
    router, detector, classifier = make_router()

    prediction = router.predict(
        make_jpeg(1280, 720),
        mode="auto",
        confidence=0.25,
        iou=0.45,
        image_size=1280,
    )

    assert detector.calls[0]["image_size"] == 1280
    assert not classifier.calls
    assert prediction.recognition_mode == "detect"
    assert prediction.model_family == "tt100k-detector"
    assert prediction.dataset == "tt100k"
    assert prediction.result_type == "detection"


def test_explicit_mode_overrides_size_rule():
    router, detector, classifier = make_router()

    compact = router.predict(make_jpeg(53, 54), mode="detect")
    large = router.predict(make_jpeg(1280, 720), mode="classify")

    assert compact.recognition_mode == "detect"
    assert large.recognition_mode == "classify"
    assert len(detector.calls) == 1
    assert len(classifier.calls) == 1
