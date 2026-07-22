"""Route traffic-sign inputs to detection or crop classification."""

from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from app.services.yolo_detector import DetectedObject, InvalidImageError


VALID_MODES = {"auto", "detect", "classify"}


@dataclass(frozen=True)
class RecognitionPrediction:
    width: int
    height: int
    inference_time_ms: float
    detections: tuple[DetectedObject, ...]
    annotated_jpeg: bytes
    recognition_mode: str
    model_family: str
    dataset: str
    result_type: str
    model_path: Path
    device: str


class LocalRecognitionRouter:
    def __init__(
        self,
        detector,
        classifier,
        crop_max_dimension: int = 512,
        classification_image_size: int = 128,
    ):
        self.detector = detector
        self.classifier = classifier
        self.crop_max_dimension = int(crop_max_dimension)
        self.classification_image_size = int(classification_image_size)

    @staticmethod
    def _dimensions(image_bytes: bytes) -> tuple[int, int]:
        try:
            with Image.open(BytesIO(image_bytes)) as image:
                image.load()
                return image.size
        except (UnidentifiedImageError, OSError, ValueError) as exc:
            raise InvalidImageError(f"Unable to decode uploaded image: {exc}") from exc

    def resolve_mode(self, image_bytes: bytes, mode: str = "auto") -> str:
        normalized_mode = str(mode).strip().lower() or "auto"
        if normalized_mode not in VALID_MODES:
            allowed = ", ".join(sorted(VALID_MODES))
            raise ValueError(f"Recognition mode must be one of: {allowed}")
        if normalized_mode != "auto":
            return normalized_mode
        width, height = self._dimensions(image_bytes)
        return "classify" if max(width, height) <= self.crop_max_dimension else "detect"

    def select_predictor(self, image_bytes: bytes, mode: str = "auto"):
        resolved_mode = self.resolve_mode(image_bytes, mode)
        predictor = self.classifier if resolved_mode == "classify" else self.detector
        return resolved_mode, predictor

    def predict(
        self,
        image_bytes: bytes,
        mode: str = "auto",
        confidence: float = 0.25,
        iou: float = 0.45,
        image_size: int = 1280,
    ) -> RecognitionPrediction:
        resolved_mode, predictor = self.select_predictor(image_bytes, mode)
        selected_image_size = (
            self.classification_image_size
            if resolved_mode == "classify"
            else image_size
        )
        prediction = predictor.predict(
            image_bytes,
            confidence=confidence,
            iou=iou,
            image_size=selected_image_size,
        )
        is_classification = resolved_mode == "classify"
        return RecognitionPrediction(
            width=prediction.width,
            height=prediction.height,
            inference_time_ms=prediction.inference_time_ms,
            detections=prediction.detections,
            annotated_jpeg=prediction.annotated_jpeg,
            recognition_mode=resolved_mode,
            model_family=(
                "gtsrb-classifier" if is_classification else "tt100k-detector"
            ),
            dataset="gtsrb" if is_classification else "tt100k",
            result_type="classification" if is_classification else "detection",
            model_path=Path(predictor.model_path),
            device=predictor.selected_device,
        )
