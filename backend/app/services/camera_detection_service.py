import base64
import binascii
from collections import deque
from time import monotonic

from app.config.settings import settings
from app.services.tt100k_labels import tt100k_label_zh
from app.services.yolo_detector import InvalidImageError, LocalYoloDetector


class CameraProtocolError(ValueError):
    pass


class CameraDetectionProcessor:
    def __init__(
        self,
        *,
        detector: LocalYoloDetector,
        clock=monotonic,
        max_frame_bytes: int | None = None,
    ):
        self.detector = detector
        self.clock = clock
        self.max_frame_bytes = max_frame_bytes or settings.CAMERA_MAX_FRAME_BYTES
        self.config: dict | None = None
        self.frame_count = 0
        self.started_at = self.clock()
        self.frame_times = deque(maxlen=30)

    def configure(self, message: dict) -> dict:
        mode = str(message.get("mode", "auto")).strip().lower()
        if mode not in {"auto", "gpu", "cpu"}:
            raise CameraProtocolError("mode must be auto, gpu, or cpu")
        try:
            confidence = float(message.get("conf", settings.YOLO_CONFIDENCE))
            iou = float(message.get("iou", settings.YOLO_IOU))
        except (TypeError, ValueError) as exc:
            raise CameraProtocolError("conf and iou must be numbers") from exc
        if not 0 <= confidence <= 1:
            raise CameraProtocolError("conf must be between 0 and 1")
        if not 0 <= iou <= 1:
            raise CameraProtocolError("iou must be between 0 and 1")

        selected_device = self.detector.selected_device
        if mode == "cpu":
            resolved_mode = "cpu"
            device = "cpu"
            image_size = settings.CAMERA_CPU_IMAGE_SIZE
        else:
            if selected_device == "cpu" and mode == "gpu":
                raise CameraProtocolError("GPU mode requested but CUDA is unavailable")
            if selected_device == "cpu":
                resolved_mode = "cpu"
                device = "cpu"
                image_size = settings.CAMERA_CPU_IMAGE_SIZE
            else:
                resolved_mode = "gpu"
                device = selected_device
                image_size = settings.CAMERA_GPU_IMAGE_SIZE

        self.detector.warmup_realtime(image_size=image_size, device=device)
        self.config = {
            "mode": resolved_mode,
            "device": device,
            "image_size": image_size,
            "confidence": confidence,
            "iou": iou,
        }
        self.frame_count = 0
        self.started_at = self.clock()
        self.frame_times.clear()
        return {"type": "config_ok", **self.config}

    def process_frame(self, encoded_frame: str) -> dict:
        if self.config is None:
            raise CameraProtocolError("Send config before camera frames")
        if not isinstance(encoded_frame, str) or not encoded_frame:
            raise CameraProtocolError("Frame data must be a Base64 string")
        if encoded_frame.startswith("data:"):
            marker = ";base64,"
            if marker not in encoded_frame:
                raise CameraProtocolError("Frame data is not valid Base64")
            encoded_frame = encoded_frame.split(marker, 1)[1]
        try:
            frame_bytes = base64.b64decode(encoded_frame, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise CameraProtocolError("Frame data is not valid Base64") from exc
        if len(frame_bytes) > self.max_frame_bytes:
            raise CameraProtocolError("Camera frame is too large")
        if not frame_bytes:
            raise CameraProtocolError("Camera frame is empty")

        try:
            prediction = self.detector.predict_realtime(
                frame_bytes,
                confidence=self.config["confidence"],
                iou=self.config["iou"],
                image_size=self.config["image_size"],
                device=self.config["device"],
            )
        except InvalidImageError as exc:
            raise CameraProtocolError(
                "Camera frame is not a valid image"
            ) from exc
        detections = []
        for detection in prediction.detections:
            class_name_cn = tt100k_label_zh(detection.class_name)
            detections.append(
                {
                    "class_id": detection.class_id,
                    "class_name": detection.class_name,
                    "class_name_cn": class_name_cn,
                    "display_name": class_name_cn or detection.class_name,
                    "confidence": round(detection.confidence, 4),
                    "bbox": [round(value, 2) for value in detection.bbox],
                }
            )

        self.frame_count += 1
        now = self.clock()
        self.frame_times.append(now)
        if len(self.frame_times) > 1:
            elapsed = max(self.frame_times[-1] - self.frame_times[0], 0.001)
            current_fps = (len(self.frame_times) - 1) / elapsed
        else:
            current_fps = 1 / max(now - self.started_at, 0.001)
        return {
            "type": "result",
            "annotated_frame": base64.b64encode(
                prediction.annotated_jpeg
            ).decode("ascii"),
            "detections": detections,
            "object_count": len(detections),
            "inference_time": round(prediction.inference_time_ms, 2),
            "fps": round(current_fps, 1),
            "frame_count": self.frame_count,
            "device": self.config["device"],
        }
