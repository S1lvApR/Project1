from collections import OrderedDict
from concurrent.futures import Future, ThreadPoolExecutor
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
from threading import BoundedSemaphore, RLock
from time import monotonic

import cv2
from sqlalchemy.orm import Session

from app.config.settings import settings
from app.core.logger import get_logger
from app.database.session import SessionLocal
from app.entity.db_models import DetectionTask
from app.services.detection_task_service import (
    DetectionTaskService,
    detection_task_service,
)
from app.services.tt100k_labels import tt100k_label_zh

logger = get_logger(__name__)


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
        if sample_rate < 1 or max_frames < 1:
            raise ValueError("sample_rate and max_frames must be positive")
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
                "progress": 0,
                "filename": safe_filename,
                "processed_frames": 0,
                "sampled_frames": 0,
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
        db = self.session_factory()
        try:
            task = db.get(DetectionTask, task_id)
            if task is None:
                raise VideoProcessingError(f"Detection task {task_id} was not found")
            task.status = "processing"
            db.commit()
            self.progress.update(task_id, status="processing")

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

            frame_index = 0
            processed_frames = 0
            sampled_frames = 0
            total_objects = 0
            total_inference_time = 0.0
            key_frames: list[dict] = []
            planned_source_frames = self._planned_source_frames(
                total_frames,
                sample_rate,
                max_frames,
            )

            while sampled_frames < max_frames:
                readable, frame = capture.read()
                if not readable:
                    break
                processed_frames += 1
                if frame_index % sample_rate != 0:
                    frame_index += 1
                    self._update_running_progress(
                        task_id,
                        processed_frames,
                        sampled_frames,
                        planned_source_frames,
                        total_objects,
                        total_inference_time,
                        key_frames,
                    )
                    continue

                encoded, jpeg = cv2.imencode(".jpg", frame)
                if not encoded:
                    raise VideoProcessingError(
                        f"Unable to encode frame {frame_index} from {filename}"
                    )
                prediction = self.detector.predict_realtime(
                    jpeg.tobytes(),
                    confidence=confidence,
                    iou=iou,
                    image_size=image_size,
                    device=self.detector.selected_device,
                )
                image_path = f"{filename}#frame={frame_index}"
                annotation_name = (
                    f"{Path(filename).stem}_frame_{frame_index:06d}.jpg"
                )
                annotated_url = self.task_service._save_annotation(
                    task_id,
                    sampled_frames,
                    annotation_name,
                    prediction.annotated_jpeg,
                )
                serialized = self.task_service._serialize_signs(
                    task_id,
                    image_path,
                    annotated_url,
                    prediction,
                )
                db.add_all(serialized["records"])
                sampled_frames += 1
                total_objects += len(serialized["items"])
                total_inference_time += prediction.inference_time_ms
                key_frames.append(
                    {
                        "frame_index": frame_index,
                        "timestamp": round(frame_index / fps, 3) if fps > 0 else 0.0,
                        "annotated_image_url": annotated_url,
                        "traffic_signs": serialized["items"],
                        "image_width": prediction.width,
                        "image_height": prediction.height,
                        "inference_time": prediction.inference_time_ms,
                    }
                )
                task.total_images = sampled_frames
                task.total_objects = total_objects
                task.total_inference_time = total_inference_time
                db.commit()
                self._update_running_progress(
                    task_id,
                    processed_frames,
                    sampled_frames,
                    planned_source_frames,
                    total_objects,
                    total_inference_time,
                    key_frames,
                )
                frame_index += 1

            if sampled_frames == 0:
                raise VideoProcessingError(f"Video contains no readable frames: {filename}")

            task.status = "completed"
            task.total_images = sampled_frames
            task.total_objects = total_objects
            task.total_inference_time = total_inference_time
            task.completed_at = datetime.now()
            db.commit()
            self.progress.update(
                task_id,
                status="completed",
                progress=100,
                processed_frames=processed_frames,
                sampled_frames=sampled_frames,
                total_objects=total_objects,
                total_inference_time=total_inference_time,
                average_inference_time=total_inference_time / sampled_frames,
                key_frames=key_frames,
            )
            self._persist_terminal_state_safely(task_id)
        except Exception as exc:
            db.rollback()
            public_error = self._public_error(exc)
            task = db.get(DetectionTask, task_id)
            if task is not None:
                task.status = "failed"
                task.error_message = public_error
                task.completed_at = datetime.now()
                db.commit()
            logger.exception("Video detection task %s failed", task_id)
            self.progress.update(
                task_id,
                status="failed",
                progress=100,
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
        task_id: int,
        processed_frames: int,
        sampled_frames: int,
        progress_total_frames: int,
        total_objects: int,
        total_inference_time: float,
        key_frames: list[dict],
    ) -> None:
        progress = (
            min(99, round(processed_frames / progress_total_frames * 100))
            if progress_total_frames > 0
            else 0
        )
        self.progress.update(
            task_id,
            progress=progress,
            processed_frames=processed_frames,
            sampled_frames=sampled_frames,
            total_objects=total_objects,
            total_inference_time=total_inference_time,
            average_inference_time=(
                total_inference_time / sampled_frames if sampled_frames else 0.0
            ),
            key_frames=key_frames,
        )

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
    def _planned_source_frames(
        total_frames: int,
        sample_rate: int,
        max_frames: int,
    ) -> int:
        sample_window = 1 + (max_frames - 1) * sample_rate
        return min(total_frames, sample_window)

    @staticmethod
    def _public_error(exc: Exception) -> str:
        if isinstance(exc, VideoProcessingError):
            return str(exc)
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
        return {
            "task_id": task.id,
            "status": task.status,
            "progress": 100 if task.status in {"completed", "failed"} else 0,
            "filename": None,
            "processed_frames": sampled,
            "sampled_frames": sampled,
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
