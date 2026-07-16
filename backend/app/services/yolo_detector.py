from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from threading import RLock
from typing import Any, Callable

import cv2
import numpy as np
from PIL import Image, UnidentifiedImageError

from app.core.logger import get_logger
from app.services.tt100k_labels import (
    TT100K_COMMON_45_CLASSES,
    build_tt100k_class_id_map,
)

logger = get_logger(__name__)


class ModelUnavailableError(RuntimeError):
    pass


class InvalidImageError(ValueError):
    pass


@dataclass(frozen=True)
class DetectedObject:
    class_id: int
    class_name: str
    confidence: float
    bbox: tuple[float, float, float, float]


@dataclass(frozen=True)
class ImagePrediction:
    width: int
    height: int
    inference_time_ms: float
    detections: tuple[DetectedObject, ...]
    annotated_jpeg: bytes


def _load_ultralytics_model(model_path: str):
    from ultralytics import YOLO

    return YOLO(model_path)


def _cuda_is_available() -> bool:
    import torch

    return bool(torch.cuda.is_available())


def _load_sahi_model(
    *,
    model_path: str,
    device: str,
    confidence_threshold: float,
    image_size: int,
):
    from sahi import AutoDetectionModel

    sahi_device = f"cuda:{device}" if str(device).isdigit() else str(device)
    return AutoDetectionModel.from_pretrained(
        model_type="yolov8",
        model_path=model_path,
        confidence_threshold=confidence_threshold,
        device=sahi_device,
        image_size=image_size,
    )


def _get_sliced_prediction(**kwargs):
    from sahi.predict import get_sliced_prediction

    return get_sliced_prediction(**kwargs)


class LocalYoloDetector:
    """Lazy, process-local wrapper around an Ultralytics detection model."""

    def __init__(
        self,
        model_path: str | Path,
        device: str = "auto",
        model_factory: Callable[[str], Any] | None = None,
        cuda_available: Callable[[], bool] | None = None,
        canonicalize_tt100k_classes: bool = False,
        use_sahi: bool = False,
        sahi_slice_height: int = 512,
        sahi_slice_width: int = 512,
        sahi_overlap_ratio: float = 0.2,
        sahi_model_image_size: int = 640,
        sahi_perform_standard_prediction: bool = True,
        sahi_model_factory: Callable[..., Any] | None = None,
        sliced_predictor: Callable[..., Any] | None = None,
    ):
        self.model_path = Path(model_path).expanduser().resolve()
        self.requested_device = str(device).strip().lower() or "auto"
        self._model_factory = model_factory or _load_ultralytics_model
        self._cuda_available = cuda_available or _cuda_is_available
        self.canonicalize_tt100k_classes = bool(canonicalize_tt100k_classes)
        self.use_sahi = bool(use_sahi)
        self.sahi_slice_height = int(sahi_slice_height)
        self.sahi_slice_width = int(sahi_slice_width)
        self.sahi_overlap_ratio = float(sahi_overlap_ratio)
        self.sahi_model_image_size = int(sahi_model_image_size)
        self.sahi_perform_standard_prediction = bool(
            sahi_perform_standard_prediction
        )
        self._sahi_model_factory = sahi_model_factory or _load_sahi_model
        self._sliced_predictor = sliced_predictor or _get_sliced_prediction
        self._model = None
        self._sahi_model = None
        self._selected_device: str | None = None
        self._lock = RLock()

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
                f"YOLO checkpoint does not exist: {self.model_path}"
            )
        if self._model is None:
            if self.use_sahi:
                return self._get_sahi_model_locked(0.25).model
            try:
                self._model = self._model_factory(str(self.model_path))
            except Exception as exc:
                raise ModelUnavailableError(
                    f"Unable to load YOLO checkpoint {self.model_path}: {exc}"
                ) from exc
            logger.info(
                "Loaded YOLO checkpoint %s for device %s",
                self.model_path,
                self.selected_device,
            )
        return self._model

    def _get_sahi_model_locked(self, confidence: float):
        if not self.model_path.is_file():
            raise ModelUnavailableError(
                f"YOLO checkpoint does not exist: {self.model_path}"
            )
        if self._sahi_model is None:
            try:
                self._sahi_model = self._sahi_model_factory(
                    model_path=str(self.model_path),
                    device=self.selected_device,
                    confidence_threshold=confidence,
                    image_size=self.sahi_model_image_size,
                )
                self._model = self._sahi_model.model
            except Exception as exc:
                raise ModelUnavailableError(
                    f"Unable to load SAHI YOLO checkpoint {self.model_path}: {exc}"
                ) from exc
            logger.info(
                "Loaded SAHI YOLO checkpoint %s for device %s",
                self.model_path,
                self.selected_device,
            )
        self._sahi_model.confidence_threshold = confidence
        self._sahi_model.image_size = self.sahi_model_image_size
        return self._sahi_model

    @property
    def class_names(self) -> dict[int, str]:
        with self._lock:
            names = self._get_model_locked().names
            if self.canonicalize_tt100k_classes:
                self._canonical_class_id_map(names)
                return dict(enumerate(TT100K_COMMON_45_CLASSES))
            return self._normalize_names(names)

    @staticmethod
    def _normalize_names(names) -> dict[int, str]:
        if isinstance(names, dict):
            return {int(class_id): str(name) for class_id, name in names.items()}
        return {class_id: str(name) for class_id, name in enumerate(names)}

    @staticmethod
    def _canonical_class_id_map(names) -> dict[int, int]:
        try:
            return build_tt100k_class_id_map(names)
        except ValueError as exc:
            raise ModelUnavailableError(
                f"Checkpoint classes are not compatible with TT100K common-45: {exc}"
            ) from exc

    @staticmethod
    def _decode_image(image_bytes: bytes) -> Image.Image:
        try:
            image = Image.open(BytesIO(image_bytes))
            image.load()
            return image.convert("RGB")
        except (UnidentifiedImageError, OSError, ValueError) as exc:
            raise InvalidImageError(f"Unable to decode uploaded image: {exc}") from exc

    def predict(
        self,
        image_bytes: bytes,
        confidence: float = 0.25,
        iou: float = 0.45,
        image_size: int = 640,
    ) -> ImagePrediction:
        image = self._decode_image(image_bytes)

        with self._lock:
            if self.use_sahi:
                return self._predict_sahi_locked(image, confidence)
            return self._predict_standard_locked(
                image,
                confidence=confidence,
                iou=iou,
                image_size=image_size,
                device=self.selected_device,
            )

    def predict_realtime(
        self,
        image_bytes: bytes,
        confidence: float = 0.25,
        iou: float = 0.45,
        image_size: int = 640,
        device: str | None = None,
    ) -> ImagePrediction:
        """Run whole-frame YOLO inference for video and camera workloads."""
        image = self._decode_image(image_bytes)
        resolved_device = self.selected_device if device is None else str(device)
        if resolved_device != "cpu" and not self._cuda_available():
            raise ModelUnavailableError(
                f"CUDA device {resolved_device} was requested but CUDA is unavailable"
            )
        with self._lock:
            return self._predict_standard_locked(
                image,
                confidence=confidence,
                iou=iou,
                image_size=image_size,
                device=resolved_device,
            )

    def warmup_realtime(self, *, image_size: int, device: str) -> None:
        """Load the model and execute one small whole-frame prediction."""
        output = BytesIO()
        Image.new("RGB", (64, 64), color="black").save(output, format="JPEG")
        self.predict_realtime(
            output.getvalue(),
            confidence=0.25,
            iou=0.45,
            image_size=image_size,
            device=device,
        )

    def _predict_standard_locked(
        self,
        image: Image.Image,
        *,
        confidence: float,
        iou: float,
        image_size: int,
        device: str,
    ) -> ImagePrediction:
        model = self._get_model_locked()
        try:
            results = model.predict(
                source=image,
                conf=confidence,
                iou=iou,
                imgsz=image_size,
                device=device,
                verbose=False,
            )
        except Exception as exc:
            raise ModelUnavailableError(f"YOLO inference failed: {exc}") from exc

        if not results:
            raise ModelUnavailableError("YOLO inference returned no image result")

        result = results[0]
        detections = self._convert_detections(result)
        height, width = getattr(result, "orig_shape", (image.height, image.width))
        return ImagePrediction(
            width=int(width),
            height=int(height),
            inference_time_ms=float(
                getattr(result, "speed", {}).get("inference", 0.0)
            ),
            detections=detections,
            annotated_jpeg=self._encode_annotated_image(result.plot()),
        )

    def _predict_sahi_locked(
        self,
        image: Image.Image,
        confidence: float,
    ) -> ImagePrediction:
        model = self._get_sahi_model_locked(confidence)
        try:
            result = self._sliced_predictor(
                image=np.asarray(image),
                detection_model=model,
                slice_height=self.sahi_slice_height,
                slice_width=self.sahi_slice_width,
                overlap_height_ratio=self.sahi_overlap_ratio,
                overlap_width_ratio=self.sahi_overlap_ratio,
                perform_standard_pred=self.sahi_perform_standard_prediction,
                verbose=0,
            )
        except Exception as exc:
            raise ModelUnavailableError(f"SAHI YOLO inference failed: {exc}") from exc

        detections = self._convert_sahi_detections(
            result.object_prediction_list,
            model.model.names,
        )
        inference_time_ms = float(
            result.durations_in_seconds.get("prediction", 0.0) * 1000
        )
        return ImagePrediction(
            width=image.width,
            height=image.height,
            inference_time_ms=inference_time_ms,
            detections=detections,
            annotated_jpeg=self._annotate_detections(image, detections),
        )

    def _convert_sahi_detections(
        self,
        object_predictions,
        names,
    ) -> tuple[DetectedObject, ...]:
        class_id_map = (
            self._canonical_class_id_map(names)
            if self.canonicalize_tt100k_classes
            else None
        )
        converted = []
        for prediction in object_predictions:
            native_class_id = int(prediction.category.id)
            if class_id_map is None:
                class_id = native_class_id
                class_name = str(prediction.category.name)
            else:
                class_id = class_id_map[native_class_id]
                class_name = TT100K_COMMON_45_CLASSES[class_id]
            converted.append(
                DetectedObject(
                    class_id=class_id,
                    class_name=class_name,
                    confidence=float(prediction.score.value),
                    bbox=tuple(float(value) for value in prediction.bbox.to_xyxy()),
                )
            )
        return tuple(converted)

    @staticmethod
    def _annotate_detections(
        image: Image.Image,
        detections: tuple[DetectedObject, ...],
    ) -> bytes:
        canvas = cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)
        font_scale = max(0.45, min(0.9, max(image.size) / 2200))
        thickness = max(1, round(font_scale * 2))
        for detection in detections:
            x1, y1, x2, y2 = (round(value) for value in detection.bbox)
            cv2.rectangle(canvas, (x1, y1), (x2, y2), (0, 210, 40), thickness)
            label = f"{detection.class_name} {detection.confidence:.2f}"
            (text_width, text_height), baseline = cv2.getTextSize(
                label,
                cv2.FONT_HERSHEY_SIMPLEX,
                font_scale,
                thickness,
            )
            text_top = max(0, y1 - text_height - baseline - 4)
            text_right = min(image.width - 1, x1 + text_width + 4)
            cv2.rectangle(
                canvas,
                (max(0, x1), text_top),
                (text_right, min(image.height - 1, text_top + text_height + baseline + 4)),
                (0, 210, 40),
                -1,
            )
            cv2.putText(
                canvas,
                label,
                (max(0, x1 + 2), text_top + text_height + 1),
                cv2.FONT_HERSHEY_SIMPLEX,
                font_scale,
                (0, 0, 0),
                thickness,
                cv2.LINE_AA,
            )
        return LocalYoloDetector._encode_annotated_image(canvas)

    def _convert_detections(self, result) -> tuple[DetectedObject, ...]:
        boxes = getattr(result, "boxes", None)
        if boxes is None:
            return ()

        coordinates = boxes.xyxy.cpu().tolist()
        confidences = boxes.conf.cpu().tolist()
        class_ids = boxes.cls.cpu().tolist()
        names = result.names
        class_id_map = (
            self._canonical_class_id_map(names)
            if self.canonicalize_tt100k_classes
            else None
        )
        converted = []
        for bbox, confidence, class_id_value in zip(
            coordinates, confidences, class_ids
        ):
            native_class_id = int(class_id_value)
            if class_id_map is None:
                class_id = native_class_id
                class_name = (
                    names[class_id] if isinstance(names, dict) else names[class_id]
                )
            else:
                class_id = class_id_map[native_class_id]
                class_name = TT100K_COMMON_45_CLASSES[class_id]
            converted.append(
                DetectedObject(
                    class_id=class_id,
                    class_name=str(class_name),
                    confidence=float(confidence),
                    bbox=tuple(float(value) for value in bbox),
                )
            )
        return tuple(converted)

    @staticmethod
    def _encode_annotated_image(image) -> bytes:
        encoded, buffer = cv2.imencode(".jpg", image)
        if not encoded:
            raise ModelUnavailableError("Unable to encode annotated image")
        return buffer.tobytes()
