from collections import OrderedDict
from concurrent.futures import Future, ThreadPoolExecutor
from copy import deepcopy
from dataclasses import dataclass, replace
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
from threading import BoundedSemaphore, RLock
from time import monotonic

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from sqlalchemy.orm import Session

from app.config.settings import settings
from app.core.logger import get_logger
from app.database.session import SessionLocal
from app.entity.db_models import DetectionTask
from app.services.detection_task_service import (
    DetectionTaskService,
    detection_task_service,
)
from app.services.tt100k_labels import (
    TT100K_COMMON_45_CLASSES,
    tt100k_label_zh,
)
from app.services.video_encoder import BrowserVideoEncoder, VideoEncodingError
from app.services.yolo_detector import DetectedObject

logger = get_logger(__name__)


GTSRB_SPEED_LIMIT_50_CLASS_ID = 2
TT100K_SPEED_LIMIT_50_CLASS_ID = TT100K_COMMON_45_CLASSES.index("pl50")
TT100K_POSSIBLE_SPEED_LIMIT_50_MISCLASSIFICATIONS = frozenset(
    {"pl40", "pl70", "pl80", "pl100", "pr40"}
)
TT100K_SPEED_LIMIT_50_TRACK_CANDIDATES = frozenset(
    {
        "pl5",
        "pl20",
        "pl30",
        "pl40",
        "pl50",
        "pl60",
        "pl70",
        "pl80",
        "pl100",
        "pl120",
        "pm20",
        "pm30",
        "pm55",
        "pr40",
    }
)
SPEED_LIMIT_50_TRACK_TTL_FRAMES = 30
SPEED_LIMIT_50_TRACK_DISTANCE_RATIO = 4.0


class VideoProcessingError(RuntimeError):
    pass


class VideoQueueFullError(RuntimeError):
    pass


class VideoStatusMigrationError(RuntimeError):
    pass


@dataclass(frozen=True)
class VideoTaskSubmission:
    task_id: int
    status: str


@dataclass(frozen=True)
class VideoOutputPaths:
    task_dir: Path
    preview_path: Path
    video_path: Path


def build_inference_schedule(
    total_frames: int,
    *,
    sample_rate: int,
    max_frames: int,
) -> tuple[int, ...]:
    if total_frames <= 0:
        return ()
    if sample_rate < 1 or max_frames < 0:
        raise ValueError(
            "sample_rate must be positive and max_frames non-negative"
        )

    candidates = list(range(0, total_frames, sample_rate))
    if candidates[-1] != total_frames - 1:
        candidates.append(total_frames - 1)
    if max_frames == 0 or max_frames >= len(candidates):
        return tuple(candidates)
    if max_frames == 1:
        return (total_frames - 1,)

    last = len(candidates) - 1
    positions = [
        round(index * last / (max_frames - 1))
        for index in range(max_frames)
    ]
    return tuple(candidates[position] for position in positions)


class VideoProgressRegistry:
    """Process-local live state with persisted task fallback after restarts."""

    def __init__(self, ttl_seconds: int | None = None, clock=monotonic):
        self._states: dict[int, dict] = {}
        self._expires_at: dict[int, float] = {}
        self._lock = RLock()
        self.ttl_seconds = ttl_seconds or settings.VIDEO_PROGRESS_TTL_SECONDS
        self.clock = clock

    def create(self, task_id: int, state: dict) -> None:
        with self._lock:
            self._prune_locked()
            self._states[task_id] = deepcopy(state)
            self._expires_at.pop(task_id, None)

    def update(self, task_id: int, **changes) -> dict:
        with self._lock:
            state = self._states[task_id]
            state.update(deepcopy(changes))
            if state.get("status") in {"completed", "failed"}:
                self._expires_at[task_id] = self.clock() + self.ttl_seconds
            return deepcopy(state)

    def get(self, task_id: int) -> dict | None:
        with self._lock:
            self._prune_locked()
            state = self._states.get(task_id)
            return deepcopy(state) if state is not None else None

    def _prune_locked(self) -> None:
        now = self.clock()
        expired = [
            task_id
            for task_id, expires_at in self._expires_at.items()
            if expires_at <= now
        ]
        for task_id in expired:
            self._states.pop(task_id, None)
            self._expires_at.pop(task_id, None)


class VideoDetectionService:
    def __init__(
        self,
        *,
        detector=None,
        task_service: DetectionTaskService | None = None,
        session_factory=SessionLocal,
        output_dir: str | Path | None = None,
        temp_dir: str | Path | None = None,
        status_dir: str | Path | None = None,
        capture_factory=None,
        executor=None,
        progress_registry: VideoProgressRegistry | None = None,
        max_pending_tasks: int | None = None,
        encoder_factory=None,
        preview_interval_frames: int | None = None,
        key_frame_interval_seconds: float | None = None,
        max_key_frames: int | None = None,
        box_persistence_frames: int | None = None,
        annotation_font_path: str | Path | None = None,
        speed_classifier=None,
        speed_refinement_enabled: bool | None = None,
        speed_refinement_min_confidence: float | None = None,
        speed_refinement_pl40_min_confidence: float | None = None,
        speed_refinement_padding_ratio: float | None = None,
    ):
        self.task_service = task_service or detection_task_service
        self.detector = detector or self.task_service.detector
        self.session_factory = session_factory
        self.output_dir = Path(output_dir or self.task_service.output_dir)
        self.task_service.output_dir = self.output_dir
        self.temp_dir = Path(temp_dir or settings.video_temp_path)
        self.status_dir = Path(status_dir or settings.video_status_path)
        self.capture_factory = capture_factory or cv2.VideoCapture
        self.executor = executor or ThreadPoolExecutor(
            max_workers=settings.VIDEO_WORKERS,
            thread_name_prefix="video-detection",
        )
        self.progress = progress_registry or VideoProgressRegistry()
        self.encoder_factory = encoder_factory or BrowserVideoEncoder
        self.preview_interval_frames = int(
            preview_interval_frames
            if preview_interval_frames is not None
            else settings.VIDEO_PREVIEW_INTERVAL_FRAMES
        )
        self.key_frame_interval_seconds = float(
            key_frame_interval_seconds
            if key_frame_interval_seconds is not None
            else settings.VIDEO_KEY_FRAME_INTERVAL_SECONDS
        )
        self.max_key_frames = int(
            max_key_frames
            if max_key_frames is not None
            else settings.VIDEO_MAX_KEY_FRAMES
        )
        self.box_persistence_frames = int(
            box_persistence_frames
            if box_persistence_frames is not None
            else settings.VIDEO_BOX_PERSISTENCE_FRAMES
        )
        router = getattr(self.task_service, "router", None)
        self.speed_classifier = speed_classifier or getattr(
            router, "classifier", None
        )
        self.speed_refinement_enabled = (
            settings.VIDEO_SPEED_REFINEMENT_ENABLED
            if speed_refinement_enabled is None
            else bool(speed_refinement_enabled)
        )
        self.speed_refinement_min_confidence = float(
            settings.VIDEO_SPEED_REFINEMENT_MIN_CONFIDENCE
            if speed_refinement_min_confidence is None
            else speed_refinement_min_confidence
        )
        self.speed_refinement_pl40_min_confidence = float(
            settings.VIDEO_SPEED_REFINEMENT_PL40_MIN_CONFIDENCE
            if speed_refinement_pl40_min_confidence is None
            else speed_refinement_pl40_min_confidence
        )
        self.speed_refinement_padding_ratio = float(
            settings.VIDEO_SPEED_REFINEMENT_PADDING_RATIO
            if speed_refinement_padding_ratio is None
            else speed_refinement_padding_ratio
        )
        self._annotation_font = self._load_annotation_font(annotation_font_path)
        self.max_pending_tasks = (
            max_pending_tasks or settings.VIDEO_MAX_PENDING_TASKS
        )
        self._admission = BoundedSemaphore(self.max_pending_tasks)
        self._futures: set[Future] = set()
        self._future_lock = RLock()

    def submit(
        self,
        *,
        db: Session,
        user_id: int,
        filename: str,
        content: bytes,
        confidence: float,
        iou: float,
        image_size: int,
        sample_rate: int,
        max_frames: int,
    ) -> VideoTaskSubmission:
        if sample_rate < 1 or max_frames < 0:
            raise ValueError(
                "sample_rate must be positive and max_frames non-negative"
            )
        if not self._admission.acquire(blocking=False):
            raise VideoQueueFullError("视频检测队列已满，请稍后重试")

        future_submitted = False
        task_id = None
        source_dir = None
        progress_created = False
        try:
            safe_filename = Path(filename).name or "video.mp4"
            scene, model_version = self.task_service.ensure_registry(db)
            task = DetectionTask(
                user_id=user_id,
                scene_id=scene.id,
                model_version_id=model_version.id,
                task_type="video",
                status="pending",
                total_images=0,
                total_objects=0,
                total_inference_time=0.0,
                conf_threshold=confidence,
                iou_threshold=iou,
                image_size=image_size,
            )
            db.add(task)
            db.commit()
            task_id = int(task.id)

            source_dir = self.temp_dir / str(task_id)
            source_dir.mkdir(parents=True, exist_ok=True)
            source_path = source_dir / f"source{Path(safe_filename).suffix.lower()}"
            try:
                source_path.write_bytes(content)
            except Exception as exc:
                logger.exception("Unable to store video upload for task %s", task_id)
                task.status = "failed"
                task.error_message = "无法保存上传视频"
                db.commit()
                shutil.rmtree(source_dir, ignore_errors=True)
                raise VideoProcessingError(task.error_message) from exc

            initial_state = {
                "task_id": task_id,
                "status": "pending",
                "stage": "pending",
                "progress": 0,
                "filename": safe_filename,
                "processed_frames": 0,
                "sampled_frames": 0,
                "inference_frames": 0,
                "detected_frames": 0,
                "total_objects": 0,
                "total_inference_time": 0.0,
                "average_inference_time": 0.0,
                "device": self.detector.selected_device,
                "metadata": {
                    "total_frames": 0,
                    "fps": 0.0,
                    "duration": 0.0,
                    "width": 0,
                    "height": 0,
                },
                "key_frames": [],
                "preview_frame_url": None,
                "preview_version": 0,
                "annotated_video_url": None,
                "download_url": None,
                "error": None,
            }
            self.progress.create(task_id, initial_state)
            progress_created = True
            future = self.executor.submit(
                self._process,
                task_id,
                safe_filename,
                source_path,
                confidence,
                iou,
                image_size,
                sample_rate,
                max_frames,
            )
            future_submitted = True
            with self._future_lock:
                self._futures.add(future)
            future.add_done_callback(self._forget_future)
            return VideoTaskSubmission(task_id=task_id, status="pending")
        except Exception as exc:
            if task_id is None:
                raise
            public_error = (
                str(exc)
                if isinstance(exc, VideoProcessingError)
                else "无法创建视频检测任务，请稍后重试"
            )
            if not isinstance(exc, VideoProcessingError):
                logger.exception(
                    "Unable to hand video task %s to the executor",
                    task_id,
                )
            try:
                db.rollback()
                failed_task = db.get(DetectionTask, task_id)
                if failed_task is not None:
                    failed_task.status = "failed"
                    failed_task.error_message = public_error
                    failed_task.completed_at = datetime.now()
                    db.commit()
            except Exception:
                logger.exception(
                    "Unable to persist submission failure for video task %s",
                    task_id,
                )
            try:
                if progress_created:
                    self.progress.update(
                        task_id,
                        status="failed",
                        progress=100,
                        error=public_error,
                    )
                    self._persist_terminal_state_safely(task_id)
            finally:
                if source_dir is not None:
                    shutil.rmtree(source_dir, ignore_errors=True)
            if isinstance(exc, VideoProcessingError):
                raise
            raise VideoProcessingError(public_error) from exc
        finally:
            if not future_submitted:
                self._admission.release()

    def _forget_future(self, future: Future) -> None:
        with self._future_lock:
            self._futures.discard(future)
        self._admission.release()

    def _process(
        self,
        task_id: int,
        filename: str,
        source_path: Path,
        confidence: float,
        iou: float,
        image_size: int,
        sample_rate: int,
        max_frames: int,
    ) -> None:
        capture = None
        encoder = None
        paths = self._output_paths(task_id, filename)
        db = self.session_factory()
        try:
            task = db.get(DetectionTask, task_id)
            if task is None:
                raise VideoProcessingError(f"Detection task {task_id} was not found")
            task.status = "processing"
            db.commit()
            self.progress.update(
                task_id,
                status="processing",
                stage="detecting",
            )

            capture = self.capture_factory(str(source_path))
            if not capture.isOpened():
                raise VideoProcessingError(f"Unable to open video: {filename}")

            total_frames = max(0, int(capture.get(cv2.CAP_PROP_FRAME_COUNT)))
            fps = max(0.0, float(capture.get(cv2.CAP_PROP_FPS)))
            width = max(0, int(capture.get(cv2.CAP_PROP_FRAME_WIDTH)))
            height = max(0, int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT)))
            if total_frames <= 0 or fps <= 0 or width <= 0 or height <= 0:
                raise VideoProcessingError("视频元数据无效，无法开始检测")
            metadata = {
                "total_frames": total_frames,
                "fps": round(fps, 3),
                "duration": round(total_frames / fps, 3) if fps > 0 else 0.0,
                "width": width,
                "height": height,
            }
            self.progress.update(task_id, metadata=metadata)

            paths.task_dir.mkdir(parents=True, exist_ok=True)
            encoder = self.encoder_factory(
                output_path=paths.video_path,
                width=width,
                height=height,
                fps=fps,
            )
            encoder.open()

            frame_index = 0
            processed_frames = 0
            inference_frames = 0
            detected_frames = 0
            total_objects = 0
            total_inference_time = 0.0
            key_frames: list[dict] = []
            inference_schedule = set(build_inference_schedule(
                total_frames,
                sample_rate=sample_rate,
                max_frames=max_frames,
            ))
            active_detections = ()
            persistence_remaining = 0
            preview_url = None
            preview_version = 0
            speed_limit_50_tracks: list[dict] = []

            while True:
                readable, frame = capture.read()
                if not readable:
                    break
                processed_frames += 1
                prediction = None
                if frame_index in inference_schedule:
                    prediction = self.detector.predict_video_frame(
                        frame,
                        confidence=confidence,
                        iou=iou,
                        image_size=image_size,
                        device=self.detector.selected_device,
                    )
                    refined_detections = self._refine_speed_limit_detections(
                        frame,
                        prediction.detections,
                        speed_limit_50_tracks=speed_limit_50_tracks,
                    )
                    if refined_detections != prediction.detections:
                        prediction = replace(
                            prediction,
                            detections=refined_detections,
                        )
                    inference_frames += 1
                    total_inference_time += prediction.inference_time_ms
                    active_detections = prediction.detections
                    if active_detections:
                        detected_frames += 1
                        total_objects += len(active_detections)
                        persistence_remaining = self.box_persistence_frames
                    else:
                        persistence_remaining = 0
                elif persistence_remaining > 0:
                    persistence_remaining -= 1
                else:
                    active_detections = ()

                annotated = self._annotate_frame(frame, active_detections)
                encoder.write(annotated)

                timestamp = round(frame_index / fps, 3)
                if (
                    prediction is not None
                    and prediction.detections
                    and self._should_save_key_frame(timestamp, key_frames)
                ):
                    annotation_name = (
                        f"{Path(filename).stem}_frame_{frame_index:06d}.jpg"
                    )
                    annotated_url = self.task_service._save_annotation(
                        task_id,
                        len(key_frames),
                        annotation_name,
                        self._encode_jpeg(annotated),
                    )
                    serialized = self.task_service._serialize_signs(
                        task_id,
                        f"{filename}#frame={frame_index}",
                        annotated_url,
                        prediction,
                    )
                    db.add_all(serialized["records"])
                    key_frames.append(
                        {
                            "frame_index": frame_index,
                            "timestamp": timestamp,
                            "annotated_image_url": annotated_url,
                            "traffic_signs": serialized["items"],
                            "image_width": prediction.width,
                            "image_height": prediction.height,
                            "inference_time": prediction.inference_time_ms,
                        }
                    )
                    task.total_images = inference_frames
                    task.total_objects = total_objects
                    task.total_inference_time = total_inference_time
                    db.commit()

                publish_preview = (
                    frame_index % self.preview_interval_frames == 0
                    or frame_index == total_frames - 1
                )
                if publish_preview:
                    preview_url, preview_version = self._publish_preview(
                        paths,
                        annotated,
                        frame_index,
                    )
                self._update_running_progress(
                    task_id=task_id,
                    processed_frames=processed_frames,
                    inference_frames=inference_frames,
                    total_frames=total_frames,
                    detected_frames=detected_frames,
                    total_objects=total_objects,
                    total_inference_time=total_inference_time,
                    key_frames=key_frames,
                    preview_frame_url=preview_url,
                    preview_version=preview_version,
                )
                frame_index += 1

            if processed_frames == 0:
                raise VideoProcessingError(f"Video contains no readable frames: {filename}")

            if preview_version != frame_index - 1:
                preview_url, preview_version = self._publish_preview(
                    paths,
                    annotated,
                    frame_index - 1,
                )
            self.progress.update(
                task_id,
                stage="finalizing",
                progress=96,
                preview_frame_url=preview_url,
                preview_version=preview_version,
            )
            final_path = encoder.close()
            annotated_video_url = self._public_upload_url(final_path)

            task.status = "completed"
            task.total_images = inference_frames
            task.total_objects = total_objects
            task.total_inference_time = total_inference_time
            task.completed_at = datetime.now()
            db.commit()
            self.progress.update(
                task_id,
                status="completed",
                stage="completed",
                progress=100,
                processed_frames=processed_frames,
                sampled_frames=inference_frames,
                inference_frames=inference_frames,
                detected_frames=detected_frames,
                total_objects=total_objects,
                total_inference_time=total_inference_time,
                average_inference_time=(
                    total_inference_time / inference_frames
                    if inference_frames
                    else 0.0
                ),
                key_frames=key_frames,
                preview_frame_url=preview_url,
                preview_version=preview_version,
                annotated_video_url=annotated_video_url,
                download_url=annotated_video_url,
            )
            self._persist_terminal_state_safely(task_id)
        except Exception as exc:
            db.rollback()
            if encoder is not None:
                try:
                    encoder.abort()
                except Exception:
                    logger.exception("Unable to abort video encoder for task %s", task_id)
            shutil.rmtree(paths.task_dir, ignore_errors=True)
            public_error = self._public_error(exc)
            task = db.get(DetectionTask, task_id)
            if task is not None:
                for result in list(task.results):
                    db.delete(result)
                task.status = "failed"
                task.error_message = public_error
                task.total_images = 0
                task.total_objects = 0
                task.total_inference_time = 0.0
                task.completed_at = datetime.now()
                db.commit()
            logger.exception("Video detection task %s failed", task_id)
            self.progress.update(
                task_id,
                status="failed",
                stage="failed",
                progress=100,
                preview_frame_url=None,
                annotated_video_url=None,
                download_url=None,
                error=public_error,
            )
            self._persist_terminal_state_safely(task_id)
        finally:
            if capture is not None:
                capture.release()
            db.close()
            shutil.rmtree(source_path.parent, ignore_errors=True)

    def _update_running_progress(
        self,
        *,
        task_id: int,
        processed_frames: int,
        inference_frames: int,
        total_frames: int,
        detected_frames: int,
        total_objects: int,
        total_inference_time: float,
        key_frames: list[dict],
        preview_frame_url: str | None,
        preview_version: int,
    ) -> None:
        progress = (
            min(95, max(1, round(processed_frames / total_frames * 95)))
            if total_frames > 0
            else 0
        )
        self.progress.update(
            task_id,
            stage="detecting",
            progress=progress,
            processed_frames=processed_frames,
            sampled_frames=inference_frames,
            inference_frames=inference_frames,
            detected_frames=detected_frames,
            total_objects=total_objects,
            total_inference_time=total_inference_time,
            average_inference_time=(
                total_inference_time / inference_frames
                if inference_frames
                else 0.0
            ),
            key_frames=key_frames,
            preview_frame_url=preview_frame_url,
            preview_version=preview_version,
        )

    def _output_paths(self, task_id: int, filename: str) -> VideoOutputPaths:
        task_dir = self.output_dir / str(task_id)
        stem = re.sub(
            r"[^A-Za-z0-9._-]+",
            "_",
            Path(filename).stem,
        ).strip("._") or "video"
        return VideoOutputPaths(
            task_dir=task_dir,
            preview_path=task_dir / "preview.jpg",
            video_path=task_dir / f"{stem}_annotated.mp4",
        )

    def _publish_preview(
        self,
        paths: VideoOutputPaths,
        frame: np.ndarray,
        frame_index: int,
    ) -> tuple[str, int]:
        paths.task_dir.mkdir(parents=True, exist_ok=True)
        temporary = paths.task_dir / "preview.tmp.jpg"
        temporary.write_bytes(self._encode_jpeg(frame))
        temporary.replace(paths.preview_path)
        return self._public_upload_url(paths.preview_path), frame_index

    def _public_upload_url(self, path: Path) -> str:
        relative = path.resolve().relative_to(self.output_dir.resolve())
        return "/uploads/detections/" + relative.as_posix()

    @staticmethod
    def _encode_jpeg(frame: np.ndarray) -> bytes:
        encoded, buffer = cv2.imencode(".jpg", frame)
        if not encoded:
            raise VideoProcessingError("Unable to encode annotated video frame")
        return buffer.tobytes()

    def _refine_speed_limit_detections(
        self,
        frame,
        detections,
        *,
        speed_limit_50_tracks: list[dict] | None = None,
    ):
        if (
            not self.speed_refinement_enabled
            or self.speed_classifier is None
        ):
            return detections

        tracks = speed_limit_50_tracks
        if tracks is not None:
            for track in tracks:
                track["age"] += 1
            tracks[:] = [
                track
                for track in tracks
                if track["age"] <= SPEED_LIMIT_50_TRACK_TTL_FRAMES
            ]
        if not detections:
            return detections

        frame_height, frame_width = frame.shape[:2]
        refined = []
        track_updates = []
        for detection in detections:
            can_confirm = detection.class_name in (
                TT100K_POSSIBLE_SPEED_LIMIT_50_MISCLASSIFICATIONS | {"pl50"}
            )
            matched_track = (
                self._match_speed_limit_50_track(detection.bbox, tracks)
                if tracks is not None
                and detection.class_name in TT100K_SPEED_LIMIT_50_TRACK_CANDIDATES
                else None
            )
            if not can_confirm and matched_track is None:
                refined.append(detection)
                continue

            confirmed = False
            if can_confirm:
                x1, y1, x2, y2 = detection.bbox
                padding = (
                    max(x2 - x1, y2 - y1)
                    * self.speed_refinement_padding_ratio
                )
                left = max(0, int(x1 - padding))
                top = max(0, int(y1 - padding))
                right = min(frame_width, int(x2 + padding + 0.999))
                bottom = min(frame_height, int(y2 + padding + 0.999))
                crop = frame[top:bottom, left:right]
                if crop.size:
                    try:
                        classification = self.speed_classifier.predict(
                            self._encode_jpeg(crop),
                            image_size=settings.GTSRB_IMAGE_SIZE,
                        )
                        classified = classification.detections[0]
                        minimum_confidence = (
                            self.speed_refinement_pl40_min_confidence
                            if detection.class_name == "pl40"
                            else self.speed_refinement_min_confidence
                        )
                        confirmed = (
                            classified.class_id
                            == GTSRB_SPEED_LIMIT_50_CLASS_ID
                            and classified.confidence
                            >= minimum_confidence
                        )
                    except Exception as exc:
                        logger.warning(
                            "Unable to refine speed-limit detection %s: %s",
                            detection.class_name,
                            exc,
                        )

            if not confirmed and matched_track is None:
                refined.append(detection)
                continue
            corrected = DetectedObject(
                class_id=TT100K_SPEED_LIMIT_50_CLASS_ID,
                class_name="pl50",
                confidence=detection.confidence,
                bbox=detection.bbox,
            )
            refined.append(corrected)
            if tracks is not None:
                track_updates.append((matched_track, corrected.bbox))

        if tracks is not None:
            for track_index, bbox in track_updates:
                if track_index is None:
                    tracks.append({"bbox": bbox, "age": 0})
                else:
                    tracks[track_index]["bbox"] = bbox
                    tracks[track_index]["age"] = 0
        return tuple(refined)

    @staticmethod
    def _match_speed_limit_50_track(bbox, tracks) -> int | None:
        if not tracks:
            return None
        x1, y1, x2, y2 = bbox
        width = max(1.0, x2 - x1)
        height = max(1.0, y2 - y1)
        center_x = (x1 + x2) / 2
        center_y = (y1 + y2) / 2
        area = width * height
        best_index = None
        best_score = None
        for index, track in enumerate(tracks):
            tx1, ty1, tx2, ty2 = track["bbox"]
            track_width = max(1.0, tx2 - tx1)
            track_height = max(1.0, ty2 - ty1)
            track_area = track_width * track_height
            area_ratio = area / track_area
            if not 0.2 <= area_ratio <= 5.0:
                continue
            delta_x = center_x - (tx1 + tx2) / 2
            delta_y = center_y - (ty1 + ty2) / 2
            max_distance = SPEED_LIMIT_50_TRACK_DISTANCE_RATIO * max(
                width,
                height,
                track_width,
                track_height,
            )
            score = delta_x * delta_x + delta_y * delta_y
            if score > max_distance * max_distance:
                continue
            if best_score is None or score < best_score:
                best_index = index
                best_score = score
        return best_index

    def _should_save_key_frame(
        self,
        timestamp: float,
        key_frames: list[dict],
    ) -> bool:
        if len(key_frames) >= self.max_key_frames:
            return False
        if not key_frames:
            return True
        return (
            timestamp - key_frames[-1]["timestamp"]
            >= self.key_frame_interval_seconds
        )

    @staticmethod
    def _load_annotation_font(configured_path: str | Path | None):
        configured = str(
            configured_path
            if configured_path is not None
            else settings.VIDEO_ANNOTATION_FONT_PATH
        ).strip()
        windows_dir = Path(os.environ.get("WINDIR", "C:/Windows"))
        candidates = ([Path(configured)] if configured else []) + [
            windows_dir / "Fonts" / "msyh.ttc",
            windows_dir / "Fonts" / "simhei.ttf",
        ]
        for candidate in candidates:
            if candidate.is_file():
                try:
                    return ImageFont.truetype(str(candidate), size=22)
                except OSError:
                    continue
        return ImageFont.load_default()

    def _annotate_frame(self, frame: np.ndarray, detections) -> np.ndarray:
        canvas = frame.copy()
        if not detections:
            return canvas
        labels = []
        height, width = canvas.shape[:2]
        for detection in detections:
            x1, y1, x2, y2 = (round(value) for value in detection.bbox)
            x1 = min(max(0, x1), width - 1)
            x2 = min(max(0, x2), width - 1)
            y1 = min(max(0, y1), height - 1)
            y2 = min(max(0, y2), height - 1)
            cv2.rectangle(canvas, (x1, y1), (x2, y2), (0, 210, 40), 2)
            display_name = (
                tt100k_label_zh(detection.class_name)
                or detection.class_name
            )
            labels.append(
                (
                    x1,
                    y1,
                    f"{display_name} ({detection.class_name}) "
                    f"{detection.confidence:.0%}",
                )
            )

        image = Image.fromarray(cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB))
        draw = ImageDraw.Draw(image)
        for x, y, label in labels:
            left, top, right, bottom = draw.textbbox(
                (0, 0),
                label,
                font=self._annotation_font,
            )
            text_width = right - left
            text_height = bottom - top
            text_top = max(0, y - text_height - 8)
            text_right = min(width - 1, x + text_width + 8)
            draw.rectangle(
                (x, text_top, text_right, text_top + text_height + 8),
                fill=(0, 210, 40),
            )
            draw.text(
                (x + 4, text_top + 4),
                label,
                font=self._annotation_font,
                fill=(0, 0, 0),
            )
        return cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)

    def get_status(self, db: Session, user_id: int, task_id: int) -> dict:
        task = self.task_service.get_task(db, user_id, task_id)
        state = self.progress.get(task_id)
        if state is not None:
            return state
        persisted = self._load_terminal_state(task_id)
        if persisted is not None:
            return persisted
        return self._persisted_status(task)

    def _persist_terminal_state(self, task_id: int) -> None:
        state = self.progress.get(task_id)
        if state is None:
            return
        self.status_dir.mkdir(parents=True, exist_ok=True)
        status_path = self.status_dir / f"{task_id}.json"
        temporary_path = self.status_dir / f"{task_id}.json.tmp"
        temporary_path.write_text(
            json.dumps(state, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        temporary_path.replace(status_path)

    def _persist_terminal_state_safely(self, task_id: int) -> None:
        try:
            self._persist_terminal_state(task_id)
        except OSError:
            logger.exception(
                "Unable to persist video status sidecar for task %s",
                task_id,
            )

    def _load_terminal_state(self, task_id: int) -> dict | None:
        status_path = self.status_dir / f"{task_id}.json"
        if not status_path.is_file():
            return None
        try:
            return json.loads(status_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            logger.exception("Unable to read video status sidecar for task %s", task_id)
            return None

    def migrate_legacy_sidecars(self) -> int:
        """Move status JSON out of the public uploads tree during upgrades."""
        try:
            self.status_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise VideoStatusMigrationError(
                "无法创建私有视频状态目录，服务已停止启动"
            ) from exc
        migrated = 0
        for legacy_path in self.output_dir.glob("*/video_status.json"):
            task_name = legacy_path.parent.name
            try:
                if not task_name.isdigit():
                    logger.warning(
                        "Removing unexpected public video sidecar %s",
                        legacy_path,
                    )
                    legacy_path.unlink(missing_ok=True)
                else:
                    target_path = self.status_dir / f"{task_name}.json"
                    if target_path.exists():
                        legacy_path.unlink()
                    else:
                        shutil.move(str(legacy_path), str(target_path))
                    migrated += 1
            except OSError as exc:
                logger.exception("Unable to migrate legacy sidecar %s", legacy_path)
                raise VideoStatusMigrationError(
                    "旧视频状态文件无法移出公开目录，服务已停止启动"
                ) from exc
        for temporary_path in self.output_dir.glob("*/video_status.json.tmp"):
            try:
                temporary_path.unlink()
            except OSError as exc:
                logger.exception(
                    "Unable to remove legacy temporary sidecar %s",
                    temporary_path,
                )
                raise VideoStatusMigrationError(
                    "旧视频临时状态文件无法从公开目录删除，服务已停止启动"
                ) from exc
        return migrated

    @staticmethod
    def _public_error(exc: Exception) -> str:
        if isinstance(exc, VideoProcessingError):
            return str(exc)
        if isinstance(exc, VideoEncodingError):
            return "无法生成可播放视频，请查看服务日志"
        return "视频检测失败，请查看服务日志"

    def _persisted_status(self, task: DetectionTask) -> dict:
        grouped = OrderedDict()
        for result in task.results:
            group = grouped.setdefault(
                result.image_path,
                {
                    "frame_index": self._frame_index(result.image_path),
                    "timestamp": 0.0,
                    "annotated_image_url": result.annotated_image_url,
                    "traffic_signs": [],
                    "image_width": result.image_width,
                    "image_height": result.image_height,
                    "inference_time": result.inference_time or 0.0,
                },
            )
            class_name_cn = result.class_name_cn or tt100k_label_zh(
                result.class_name
            )
            x1, y1, x2, y2 = result.bbox
            group["traffic_signs"].append(
                {
                    "type": result.class_name,
                    "class_name": result.class_name,
                    "class_name_cn": class_name_cn,
                    "display_name": class_name_cn or result.class_name,
                    "class_id": result.class_id,
                    "confidence": round(result.confidence * 100, 2),
                    "bbox": result.bbox,
                    "location": {
                        "left": x1,
                        "top": y1,
                        "width": max(0.0, x2 - x1),
                        "height": max(0.0, y2 - y1),
                    },
                }
            )
        sampled = task.total_images or len(grouped)
        total_time = task.total_inference_time or 0.0
        task_dir = self.output_dir / str(task.id)
        preview_path = task_dir / "preview.jpg"
        video_paths = sorted(task_dir.glob("*_annotated.mp4"))
        preview_url = (
            self._public_upload_url(preview_path)
            if preview_path.is_file()
            else None
        )
        annotated_video_url = (
            self._public_upload_url(video_paths[0])
            if video_paths
            else None
        )
        return {
            "task_id": task.id,
            "status": task.status,
            "stage": (
                "completed"
                if task.status == "completed"
                else "failed"
                if task.status == "failed"
                else "pending"
            ),
            "progress": 100 if task.status in {"completed", "failed"} else 0,
            "filename": None,
            "processed_frames": sampled,
            "sampled_frames": sampled,
            "inference_frames": sampled,
            "detected_frames": len(grouped),
            "total_objects": task.total_objects or 0,
            "total_inference_time": total_time,
            "average_inference_time": total_time / sampled if sampled else 0.0,
            "device": self.detector.selected_device,
            "metadata": {
                "total_frames": 0,
                "fps": 0.0,
                "duration": 0.0,
                "width": 0,
                "height": 0,
            },
            "key_frames": list(grouped.values()),
            "preview_frame_url": preview_url,
            "preview_version": max(
                (frame["frame_index"] for frame in grouped.values()),
                default=0,
            ),
            "annotated_video_url": annotated_video_url,
            "download_url": annotated_video_url,
            "error": task.error_message,
        }

    @staticmethod
    def _frame_index(image_path: str) -> int:
        match = re.search(r"#frame=(\d+)$", image_path or "")
        return int(match.group(1)) if match else 0

    def shutdown(self) -> None:
        shutdown = getattr(self.executor, "shutdown", None)
        if shutdown is not None:
            shutdown(wait=True, cancel_futures=False)


video_progress_registry = VideoProgressRegistry()
video_detection_service = VideoDetectionService(
    progress_registry=video_progress_registry,
)
