import base64
from io import BytesIO

from PIL import Image
import pytest

from app.services.camera_detection_service import (
    CameraDetectionProcessor,
    CameraProtocolError,
)
from app.services.yolo_detector import DetectedObject, ImagePrediction, InvalidImageError


def make_jpeg():
    output = BytesIO()
    Image.new("RGB", (32, 24), color="white").save(output, format="JPEG")
    return output.getvalue()


class FakeCameraDetector:
    def __init__(self, selected_device="0"):
        self.selected_device = selected_device
        self.warmup_calls = []
        self.predict_calls = []

    def warmup_realtime(self, *, image_size, device):
        self.warmup_calls.append((image_size, device))

    def predict_realtime(self, image_bytes, confidence, iou, image_size, device):
        if image_bytes == b"not-an-image":
            raise InvalidImageError("decoder details")
        self.predict_calls.append(
            (image_bytes, confidence, iou, image_size, device)
        )
        return ImagePrediction(
            width=32,
            height=24,
            inference_time_ms=20.0,
            detections=(
                DetectedObject(
                    class_id=29,
                    class_name="pl60",
                    confidence=0.92,
                    bbox=(1.0, 2.0, 20.0, 22.0),
                ),
            ),
            annotated_jpeg=b"annotated",
        )


def test_camera_config_prefers_gpu_and_warms_up_model():
    detector = FakeCameraDetector("0")
    processor = CameraDetectionProcessor(detector=detector)

    response = processor.configure(
        {"type": "config", "mode": "auto", "conf": 0.3, "iou": 0.5}
    )

    assert response == {
        "type": "config_ok",
        "mode": "gpu",
        "device": "0",
        "image_size": 640,
        "confidence": 0.3,
        "iou": 0.5,
    }
    assert detector.warmup_calls == [(640, "0")]


def test_camera_cpu_mode_uses_lower_resolution_and_returns_chinese_result():
    detector = FakeCameraDetector("0")
    times = iter([99.9, 100.0, 100.2])
    processor = CameraDetectionProcessor(
        detector=detector,
        clock=lambda: next(times),
    )
    processor.configure(
        {"type": "config", "mode": "cpu", "conf": 0.25, "iou": 0.45}
    )
    encoded = base64.b64encode(make_jpeg()).decode("ascii")

    response = processor.process_frame(f"data:image/jpeg;base64,{encoded}")

    assert detector.warmup_calls == [(416, "cpu")]
    assert detector.predict_calls[0][3:] == (416, "cpu")
    assert response["type"] == "result"
    assert response["annotated_frame"] == base64.b64encode(b"annotated").decode(
        "ascii"
    )
    assert response["detections"][0]["display_name"] == "最高限速 60 km/h"
    assert response["object_count"] == 1
    assert response["inference_time"] == 20.0
    assert response["fps"] == 5.0
    assert response["frame_count"] == 1
    assert response["device"] == "cpu"


def test_camera_protocol_rejects_frames_before_config_and_unavailable_gpu():
    cpu_detector = FakeCameraDetector("cpu")
    processor = CameraDetectionProcessor(detector=cpu_detector)

    with pytest.raises(CameraProtocolError, match="config"):
        processor.process_frame(base64.b64encode(make_jpeg()).decode("ascii"))
    with pytest.raises(CameraProtocolError, match="GPU"):
        processor.configure({"type": "config", "mode": "gpu"})


def test_camera_protocol_rejects_invalid_and_oversized_base64_frames():
    detector = FakeCameraDetector()
    processor = CameraDetectionProcessor(detector=detector, max_frame_bytes=4)
    processor.configure({"type": "config", "mode": "gpu"})

    with pytest.raises(CameraProtocolError, match="Base64"):
        processor.process_frame("not-base64")
    with pytest.raises(CameraProtocolError, match="too large"):
        processor.process_frame(base64.b64encode(b"12345").decode("ascii"))


def test_camera_protocol_converts_non_image_bytes_to_protocol_error():
    detector = FakeCameraDetector()
    processor = CameraDetectionProcessor(detector=detector)
    processor.configure({"type": "config", "mode": "gpu"})

    with pytest.raises(CameraProtocolError, match="valid image"):
        processor.process_frame(
            base64.b64encode(b"not-an-image").decode("ascii")
        )
