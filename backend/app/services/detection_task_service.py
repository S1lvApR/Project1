from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import re

from sqlalchemy.orm import Session

from app.config.settings import settings
from app.core.logger import get_logger
from app.entity.db_models import (
    DetectionResult,
    DetectionScene,
    DetectionTask,
    ModelVersion,
)
from app.services.gtsrb_classifier import LocalSignClassifier
from app.services.gtsrb_labels import GTSRB_LABELS_ZH
from app.services.recognition_router import LocalRecognitionRouter
from app.services.tt100k_labels import tt100k_label_zh
from app.services.yolo_detector import (
    ImagePrediction,
    InvalidImageError,
    LocalYoloDetector,
    ModelUnavailableError,
)

logger = get_logger(__name__)


@dataclass(frozen=True)
class DetectionInput:
    filename: str
    content: bytes


@dataclass
class DetectionTaskOutcome:
    task: DetectionTask
    scene: DetectionScene
    model_version: ModelVersion
    images: list[dict]
    device: str


class TaskNotFoundError(LookupError):
    pass


class DetectionTaskService:
    """Persist local detector and classifier predictions as detection tasks."""

    SCENE_NAME = "tt100k_traffic_signs"
    SCENE_DISPLAY_NAME = "TT100K traffic-sign detection"
    MODEL_VERSION = "v1.0.0"
    MODEL_NAME = "tt100k-yolo11n"

    def __init__(
        self,
        detector=None,
        router: LocalRecognitionRouter | None = None,
        output_dir: str | Path | None = None,
    ):
        self.detector = detector or LocalYoloDetector(
            model_path=settings.yolo_model_path,
            device=settings.YOLO_DEVICE,
            canonicalize_tt100k_classes=settings.YOLO_CANONICALIZE_TT100K_CLASSES,
            use_sahi=settings.YOLO_USE_SAHI,
            sahi_slice_height=settings.YOLO_SAHI_SLICE_HEIGHT,
            sahi_slice_width=settings.YOLO_SAHI_SLICE_WIDTH,
            sahi_overlap_ratio=settings.YOLO_SAHI_OVERLAP_RATIO,
            sahi_model_image_size=settings.YOLO_SAHI_MODEL_IMAGE_SIZE,
            sahi_perform_standard_prediction=settings.YOLO_SAHI_STANDARD_PREDICTION,
        )
        self.router = router
        self.output_dir = Path(output_dir or settings.detection_output_path)

    def ensure_registry(
        self,
        db: Session,
        predictor=None,
        recognition_mode: str = "detect",
    ) -> tuple[DetectionScene, ModelVersion]:
        predictor = predictor or self.detector
        is_classification = recognition_mode == "classify"
        scene_name = "gtsrb_traffic_signs" if is_classification else self.SCENE_NAME
        scene_display_name = (
            "GTSRB traffic-sign classification"
            if is_classification
            else self.SCENE_DISPLAY_NAME
        )
        model_name = (
            "gtsrb-yolo11n-cls" if is_classification else settings.YOLO_MODEL_NAME
        )
        model_type = (
            "yolo11n-cls" if is_classification else settings.YOLO_MODEL_TYPE
        )
        class_names = predictor.class_names
        ordered_names = [class_names[key] for key in sorted(class_names)]
        class_names_cn = None
        if not is_classification:
            class_names_cn = {
                name: label
                for name in ordered_names
                if (label := tt100k_label_zh(name)) is not None
            }

        scene = (
            db.query(DetectionScene)
            .filter(DetectionScene.name == scene_name)
            .first()
        )
        if scene is None:
            scene = DetectionScene(
                name=scene_name,
                display_name=scene_display_name,
                description=(
                    "Local GTSRB crop classification"
                    if is_classification
                    else "Local TT100K traffic-sign detection"
                ),
                category="traffic",
                class_names=ordered_names,
                class_names_cn=class_names_cn,
                is_active=True,
            )
            db.add(scene)
            db.flush()
        else:
            if scene.class_names != ordered_names:
                scene.class_names = ordered_names
            if not is_classification and scene.class_names_cn != class_names_cn:
                scene.class_names_cn = class_names_cn

        model_path = str(predictor.model_path)
        model_version = (
            db.query(ModelVersion)
            .filter(
                ModelVersion.scene_id == scene.id,
                ModelVersion.model_path == model_path,
            )
            .first()
        )
        if model_version is None:
            db.query(ModelVersion).filter(ModelVersion.scene_id == scene.id).update(
                {ModelVersion.is_default: False}
            )
            model_version = ModelVersion(
                scene_id=scene.id,
                version=self.MODEL_VERSION,
                model_name=model_name,
                model_type=model_type,
                status="active",
                model_path=model_path,
                file_size=(
                    predictor.model_path.stat().st_size
                    if predictor.model_path.is_file()
                    else None
                ),
                is_default=True,
                description=(
                    "GTSRB classifier checkpoint used by local inference"
                    if is_classification
                    else "TT100K detector checkpoint used by local inference"
                ),
            )
            db.add(model_version)
        else:
            model_version.model_name = model_name
            model_version.model_type = model_type
            model_version.is_default = True

        db.commit()
        db.refresh(scene)
        db.refresh(model_version)
        return scene, model_version

    def run_task(
        self,
        db: Session,
        user_id: int,
        images: list[DetectionInput],
        task_type: str,
        confidence: float,
        iou: float,
        image_size: int,
        mode: str = "detect",
    ) -> DetectionTaskOutcome:
        if not images:
            raise ValueError("At least one image is required")

        registry_mode = "detect"
        registry_predictor = self.detector
        if self.router is not None:
            registry_mode, registry_predictor = self.router.select_predictor(
                images[0].content,
                mode,
            )
        scene, model_version = self.ensure_registry(
            db,
            predictor=registry_predictor,
            recognition_mode=registry_mode,
        )
        task = DetectionTask(
            user_id=user_id,
            scene_id=scene.id,
            model_version_id=model_version.id,
            task_type=task_type,
            status="processing",
            total_images=len(images),
            total_objects=0,
            total_inference_time=0,
            conf_threshold=confidence,
            iou_threshold=iou,
            image_size=image_size,
        )
        db.add(task)
        db.commit()
        db.refresh(task)

        image_results: list[dict] = []
        errors: list[str] = []
        total_objects = 0
        total_inference_time = 0.0
        successful_images = 0
        used_devices: set[str] = set()

        for index, image in enumerate(images):
            try:
                if self.router is None:
                    prediction = self.detector.predict(
                        image.content,
                        confidence=confidence,
                        iou=iou,
                        image_size=image_size,
                    )
                else:
                    prediction = self.router.predict(
                        image.content,
                        mode=mode,
                        confidence=confidence,
                        iou=iou,
                        image_size=image_size,
                    )
                recognition_mode = getattr(prediction, "recognition_mode", "detect")
                result_type = getattr(prediction, "result_type", "detection")
                dataset = getattr(prediction, "dataset", "tt100k")
                model_family = getattr(
                    prediction,
                    "model_family",
                    "tt100k-detector",
                )
                used_devices.add(
                    getattr(prediction, "device", self.detector.selected_device)
                )
                annotated_url = self._save_annotation(
                    task.id,
                    index,
                    image.filename,
                    prediction.annotated_jpeg,
                )
                signs = self._serialize_signs(
                    task.id,
                    image.filename,
                    annotated_url,
                    prediction,
                    recognition_mode=recognition_mode,
                    result_type=result_type,
                    dataset=dataset,
                )
                db.add_all(signs["records"])
                total_objects += len(signs["items"])
                total_inference_time += prediction.inference_time_ms
                successful_images += 1
                image_results.append(
                    {
                        "image_index": index,
                        "filename": image.filename,
                        "success": True,
                        "error": None,
                        "traffic_signs": signs["items"],
                        "traffic_lights": [],
                        "annotated_image_url": annotated_url,
                        "image_width": prediction.width,
                        "image_height": prediction.height,
                        "inference_time": prediction.inference_time_ms,
                        "recognition_mode": recognition_mode,
                        "result_type": result_type,
                        "dataset": dataset,
                        "model_family": model_family,
                    }
                )
            except InvalidImageError as exc:
                error = f"{image.filename}: {exc}"
                errors.append(error)
                image_results.append(
                    {
                        "image_index": index,
                        "filename": image.filename,
                        "success": False,
                        "error": str(exc),
                        "traffic_signs": [],
                        "traffic_lights": [],
                        "annotated_image_url": None,
                    }
                )
            except ModelUnavailableError as exc:
                self._mark_failed(db, task, str(exc))
                raise
            except Exception as exc:
                logger.exception("Detection task %s failed", task.id)
                self._mark_failed(db, task, str(exc))
                raise ModelUnavailableError(
                    f"Detection task {task.id} failed: {exc}"
                ) from exc

        task.total_objects = total_objects
        task.total_inference_time = total_inference_time
        task.status = "completed" if successful_images else "failed"
        task.error_message = "; ".join(errors) if errors else None
        task.completed_at = datetime.now()
        db.commit()
        db.refresh(task)

        if len(used_devices) == 1:
            outcome_device = next(iter(used_devices))
        elif used_devices:
            outcome_device = "mixed"
        else:
            outcome_device = registry_predictor.selected_device
        return DetectionTaskOutcome(
            task=task,
            scene=scene,
            model_version=model_version,
            images=image_results,
            device=outcome_device,
        )

    @staticmethod
    def _mark_failed(db: Session, task: DetectionTask, error: str) -> None:
        task.status = "failed"
        task.error_message = error
        task.completed_at = datetime.now()
        db.commit()

    def _save_annotation(
        self,
        task_id: int,
        index: int,
        filename: str,
        jpeg_bytes: bytes,
    ) -> str:
        task_dir = self.output_dir / str(task_id)
        task_dir.mkdir(parents=True, exist_ok=True)
        stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(filename).stem).strip("._")
        safe_stem = stem or "image"
        output_name = f"{index:04d}_{safe_stem}.jpg"
        (task_dir / output_name).write_bytes(jpeg_bytes)
        return f"/uploads/detections/{task_id}/{output_name}"

    @staticmethod
    def _serialize_signs(
        task_id: int,
        filename: str,
        annotated_url: str,
        prediction: ImagePrediction,
        recognition_mode: str = "detect",
        result_type: str = "detection",
        dataset: str = "tt100k",
    ) -> dict:
        items = []
        records = []
        for detection in prediction.detections:
            x1, y1, x2, y2 = detection.bbox
            bbox = [x1, y1, x2, y2]
            class_name_cn = (
                GTSRB_LABELS_ZH[detection.class_id]
                if recognition_mode == "classify"
                and 0 <= detection.class_id < len(GTSRB_LABELS_ZH)
                else tt100k_label_zh(detection.class_name)
            )
            items.append(
                {
                    "type": detection.class_name,
                    "value": None,
                    "unit": None,
                    "confidence": round(detection.confidence * 100, 2),
                    "location": {
                        "left": x1,
                        "top": y1,
                        "width": max(0.0, x2 - x1),
                        "height": max(0.0, y2 - y1),
                    },
                    "bbox": bbox,
                    "class_id": detection.class_id,
                    "class_name": detection.class_name,
                    "class_name_cn": class_name_cn,
                    "display_name": class_name_cn or detection.class_name,
                    "recognition_mode": recognition_mode,
                    "result_type": result_type,
                    "dataset": dataset,
                }
            )
            records.append(
                DetectionResult(
                    task_id=task_id,
                    image_path=filename,
                    annotated_image_url=annotated_url,
                    class_name=detection.class_name,
                    class_name_cn=class_name_cn,
                    class_id=detection.class_id,
                    confidence=detection.confidence,
                    bbox=bbox,
                    inference_time=prediction.inference_time_ms,
                    image_width=prediction.width,
                    image_height=prediction.height,
                )
            )
        return {"items": items, "records": records}

    def list_tasks(
        self,
        db: Session,
        user_id: int,
        limit: int = 50,
    ) -> list[DetectionTask]:
        return (
            db.query(DetectionTask)
            .filter(DetectionTask.user_id == user_id)
            .order_by(DetectionTask.created_at.desc())
            .limit(limit)
            .all()
        )

    def get_task(self, db: Session, user_id: int, task_id: int) -> DetectionTask:
        task = (
            db.query(DetectionTask)
            .filter(
                DetectionTask.id == task_id,
                DetectionTask.user_id == user_id,
            )
            .first()
        )
        if task is None:
            raise TaskNotFoundError(f"Detection task {task_id} was not found")
        return task


_default_detector = LocalYoloDetector(
    model_path=settings.yolo_model_path,
    device=settings.YOLO_DEVICE,
    canonicalize_tt100k_classes=settings.YOLO_CANONICALIZE_TT100K_CLASSES,
    use_sahi=settings.YOLO_USE_SAHI,
    sahi_slice_height=settings.YOLO_SAHI_SLICE_HEIGHT,
    sahi_slice_width=settings.YOLO_SAHI_SLICE_WIDTH,
    sahi_overlap_ratio=settings.YOLO_SAHI_OVERLAP_RATIO,
    sahi_model_image_size=settings.YOLO_SAHI_MODEL_IMAGE_SIZE,
    sahi_perform_standard_prediction=settings.YOLO_SAHI_STANDARD_PREDICTION,
)
_default_classifier = LocalSignClassifier(
    model_path=settings.gtsrb_model_path,
    device=settings.GTSRB_DEVICE,
)
detection_task_service = DetectionTaskService(
    detector=_default_detector,
    router=LocalRecognitionRouter(
        detector=_default_detector,
        classifier=_default_classifier,
        crop_max_dimension=settings.GTSRB_CROP_MAX_DIMENSION,
        classification_image_size=settings.GTSRB_IMAGE_SIZE,
    ),
)
