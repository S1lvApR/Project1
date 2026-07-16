"""Local GTSRB crop classifier."""

from io import BytesIO
from pathlib import Path
from threading import RLock
from typing import Any, Callable

from PIL import Image, ImageDraw, UnidentifiedImageError

from app.core.logger import get_logger
from app.services.gtsrb_labels import GTSRB_LABELS
from app.services.yolo_detector import (
    DetectedObject,
    ImagePrediction,
    InvalidImageError,
    ModelUnavailableError,
)

logger = get_logger(__name__)


def _load_ultralytics_model(model_path: str):
    from ultralytics import YOLO

    return YOLO(model_path)


def _cuda_is_available() -> bool:
    import torch

    return bool(torch.cuda.is_available())


def _scalar(value):
    return value.item() if hasattr(value, "item") else value


class LocalSignClassifier:
    """Lazy, process-local wrapper around an Ultralytics classifier."""

    def __init__(
        self,
        model_path: str | Path,
        device: str = "auto",
        model_factory: Callable[[str], Any] | None = None,
        cuda_available: Callable[[], bool] | None = None,
    ):
        self.model_path = Path(model_path).expanduser().resolve()
        self.requested_device = str(device).strip().lower() or "auto"
        self._model_factory = model_factory or _load_ultralytics_model
        self._cuda_available = cuda_available or _cuda_is_available
        self._model = None
        self._selected_device: str | None = None
        self._lock = RLock()

    @property
    def class_names(self) -> dict[int, str]:
        return {class_id: name for class_id, name in enumerate(GTSRB_LABELS)}

    @property
    def selected_device(self) -> str:
        if self._selected_device is None:
            if self.requested_device == "auto":
                self._selected_device = "0" if self._cuda_available() else "cpu"
            elif self.requested_device == "gpu":
                self._selected_device = "0"
            else:
                self._selected_device = self.requested_device
            if self._selected_device != "cpu" and not self._cuda_available():
                raise ModelUnavailableError(
                    f"CUDA device {self._selected_device} was requested but CUDA is unavailable"
                )
        return self._selected_device

    def _get_model_locked(self):
        if not self.model_path.is_file():
            raise ModelUnavailableError(
                f"GTSRB checkpoint does not exist: {self.model_path}"
            )
        if self._model is None:
            try:
                self._model = self._model_factory(str(self.model_path))
            except Exception as exc:
                raise ModelUnavailableError(
                    f"Unable to load GTSRB checkpoint {self.model_path}: {exc}"
                ) from exc
            logger.info(
                "Loaded GTSRB checkpoint %s for device %s",
                self.model_path,
                self.selected_device,
            )
        return self._model

    @staticmethod
    def _decode_image(image_bytes: bytes) -> Image.Image:
        try:
            image = Image.open(BytesIO(image_bytes))
            image.load()
            return image.convert("RGB")
        except (UnidentifiedImageError, OSError, ValueError) as exc:
            raise InvalidImageError(f"Unable to decode uploaded image: {exc}") from exc

    @staticmethod
    def _annotate(image: Image.Image, class_id: int, confidence: float) -> bytes:
        annotated = image.copy()
        draw = ImageDraw.Draw(annotated)
        width, height = annotated.size
        draw.rectangle((0, 0, max(0, width - 1), max(0, height - 1)), outline=(220, 38, 38), width=2)
        label = f"{class_id}: {GTSRB_LABELS[class_id]} {confidence:.1%}"
        strip_height = min(16, height)
        draw.rectangle((0, 0, width, strip_height), fill=(0, 0, 0))
        draw.text((2, 2), label, fill=(255, 255, 255))
        output = BytesIO()
        annotated.save(output, format="JPEG", quality=90)
        return output.getvalue()

    def predict(
        self,
        image_bytes: bytes,
        confidence: float = 0.0,
        iou: float = 0.0,
        image_size: int = 128,
    ) -> ImagePrediction:
        del confidence, iou
        image = self._decode_image(image_bytes)
        with self._lock:
            model = self._get_model_locked()
            try:
                results = model.predict(
                    source=image,
                    imgsz=image_size,
                    device=self.selected_device,
                    verbose=False,
                )
            except Exception as exc:
                raise ModelUnavailableError(f"GTSRB inference failed: {exc}") from exc
            if not results:
                raise ModelUnavailableError("GTSRB inference returned no image result")
            result = results[0]
            probabilities = getattr(result, "probs", None)
            if probabilities is None:
                raise ModelUnavailableError("GTSRB inference returned no probabilities")
            class_id = int(_scalar(probabilities.top1))
            class_confidence = float(_scalar(probabilities.top1conf))
            if not 0 <= class_id < len(GTSRB_LABELS):
                raise ModelUnavailableError(f"GTSRB classifier returned invalid class ID {class_id}")
            annotated_jpeg = self._annotate(image, class_id, class_confidence)

        width, height = image.size
        return ImagePrediction(
            width=width,
            height=height,
            inference_time_ms=float(getattr(result, "speed", {}).get("inference", 0.0)),
            detections=(
                DetectedObject(
                    class_id=class_id,
                    class_name=GTSRB_LABELS[class_id],
                    confidence=class_confidence,
                    bbox=(0.0, 0.0, float(width), float(height)),
                ),
            ),
            annotated_jpeg=annotated_jpeg,
        )
