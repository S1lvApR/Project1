from concurrent.futures import Future
from io import BytesIO

import cv2
import numpy as np
from PIL import Image
import pytest
from sqlalchemy.orm import sessionmaker

from app.entity.db_models import DetectionResult, DetectionTask, User
from app.services.detection_task_service import DetectionTaskService
from app.services.video_detection_service import (
    VideoDetectionService,
    VideoProgressRegistry,
    VideoQueueFullError,
    VideoStatusMigrationError,
)
from app.services.yolo_detector import (
    DetectedObject,
    ImagePrediction,
    ModelUnavailableError,
)


class ImmediateExecutor:
    def submit(self, function, *args, **kwargs):
        future = Future()
        try:
            future.set_result(function(*args, **kwargs))
        except Exception as exc:
            future.set_exception(exc)
        return future

    def shutdown(self, **_kwargs):
        return None


class DeferredExecutor:
    def __init__(self):
        self.pending = []
        self.shutdown_options = None

    def submit(self, function, *args, **kwargs):
        future = Future()
        self.pending.append((future, function, args, kwargs))
        return future

    def run_all(self):
        for future, function, args, kwargs in list(self.pending):
            try:
                future.set_result(function(*args, **kwargs))
            except Exception as exc:
                future.set_exception(exc)
        self.pending.clear()

    def shutdown(self, **options):
        self.shutdown_options = options


class FailingExecutor:
    def submit(self, *_args, **_kwargs):
        raise RuntimeError("executor internals")

    def shutdown(self, **_options):
        return None


class CompensationCommitFailingSession:
    def __init__(self, session, fail_on_commit):
        self.session = session
        self.fail_on_commit = fail_on_commit
        self.commit_count = 0

    def __getattr__(self, name):
        return getattr(self.session, name)

    def commit(self):
        self.commit_count += 1
        if self.commit_count == self.fail_on_commit:
            raise RuntimeError("database unavailable during compensation")
        return self.session.commit()


class FakeCapture:
    def __init__(self, frames, opened=True, fps=10.0):
        self.frames = list(frames)
        self.opened = opened
        self.fps = fps
        self.index = 0
        self.released = False

    def isOpened(self):
        return self.opened

    def get(self, prop):
        if prop == cv2.CAP_PROP_FRAME_COUNT:
            return len(self.frames)
        if prop == cv2.CAP_PROP_FPS:
            return self.fps
        if prop == cv2.CAP_PROP_FRAME_WIDTH:
            return self.frames[0].shape[1] if self.frames else 0
        if prop == cv2.CAP_PROP_FRAME_HEIGHT:
            return self.frames[0].shape[0] if self.frames else 0
        return 0

    def read(self):
        if not self.opened or self.index >= len(self.frames):
            return False, None
        frame = self.frames[self.index]
        self.index += 1
        return True, frame

    def release(self):
        self.released = True


class FakeRealtimeDetector:
    selected_device = "0"
    class_names = {0: "pl60"}

    def __init__(self, model_path, detections=True, failure=None):
        self.model_path = model_path
        self.calls = []
        self.with_detections = detections
        self.failure = failure

    def predict_realtime(self, image_bytes, confidence, iou, image_size, device=None):
        if self.failure is not None:
            raise self.failure
        with Image.open(BytesIO(image_bytes)) as image:
            width, height = image.size
        self.calls.append(
            {
                "confidence": confidence,
                "iou": iou,
                "image_size": image_size,
                "device": device,
            }
        )
        return ImagePrediction(
            width=width,
            height=height,
            inference_time_ms=8.0,
            detections=(
                DetectedObject(
                    class_id=29,
                    class_name="pl60",
                    confidence=0.9,
                    bbox=(1.0, 2.0, 12.0, 14.0),
                ),
            ) if self.with_detections else (),
            annotated_jpeg=b"annotated-frame",
        )


def create_user(db_session, username):
    user = User(
        username=username,
        email=f"{username}@example.com",
        hashed_password="test-hash",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


def build_service(
    db_session,
    tmp_path,
    capture,
    *,
    executor=None,
    max_pending_tasks=None,
    detections=True,
    failure=None,
    progress_registry=None,
):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    detector = FakeRealtimeDetector(
        model_path,
        detections=detections,
        failure=failure,
    )
    task_service = DetectionTaskService(
        detector=detector,
        output_dir=tmp_path / "detections",
    )
    worker_sessions = sessionmaker(bind=db_session.get_bind())
    service = VideoDetectionService(
        detector=detector,
        task_service=task_service,
        session_factory=worker_sessions,
        output_dir=tmp_path / "detections",
        temp_dir=tmp_path / "videos",
        status_dir=tmp_path / "video-status",
        capture_factory=lambda _path: capture,
        executor=executor or ImmediateExecutor(),
        max_pending_tasks=max_pending_tasks,
        progress_registry=progress_registry,
    )
    return service, detector


def test_video_task_samples_frames_persists_results_and_cleans_source(
    db_session, tmp_path
):
    user = create_user(db_session, "video_service_user")
    frames = [np.full((24, 32, 3), value, dtype=np.uint8) for value in range(6)]
    capture = FakeCapture(frames)
    service, detector = build_service(db_session, tmp_path, capture)

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="road.mp4",
        content=b"fake-video",
        confidence=0.3,
        iou=0.5,
        image_size=640,
        sample_rate=2,
        max_frames=3,
    )
    db_session.expire_all()
    status = service.get_status(db_session, user.id, submission.task_id)
    task = db_session.get(DetectionTask, submission.task_id)
    records = (
        db_session.query(DetectionResult)
        .filter(DetectionResult.task_id == submission.task_id)
        .all()
    )

    assert status["status"] == "completed"
    assert status["progress"] == 100
    assert status["sampled_frames"] == 3
    assert [frame["frame_index"] for frame in status["key_frames"]] == [0, 2, 4]
    assert status["key_frames"][0]["traffic_signs"][0]["display_name"] == "最高限速 60 km/h"
    assert status["metadata"] == {
        "total_frames": 6,
        "fps": 10.0,
        "duration": 0.6,
        "width": 32,
        "height": 24,
    }
    assert task.status == "completed"
    assert task.total_images == 3
    assert task.total_objects == 3
    assert len(records) == 3
    assert records[0].image_path == "road.mp4#frame=0"
    assert all(call["device"] == "0" for call in detector.calls)
    assert capture.released is True
    assert list((tmp_path / "videos").glob("**/*")) == []


def test_video_task_marks_decode_failure_and_cleans_source(db_session, tmp_path):
    user = create_user(db_session, "video_failure_user")
    capture = FakeCapture([], opened=False)
    service, _detector = build_service(db_session, tmp_path, capture)

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="broken.mp4",
        content=b"broken",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=5,
        max_frames=50,
    )
    db_session.expire_all()
    status = service.get_status(db_session, user.id, submission.task_id)

    assert status["status"] == "failed"
    assert "Unable to open video" in status["error"]
    assert capture.released is True
    assert list((tmp_path / "videos").glob("**/*")) == []


def test_video_task_rejects_invalid_metadata(db_session, tmp_path):
    user = create_user(db_session, "video_metadata_user")
    frames = [np.zeros((24, 32, 3), dtype=np.uint8)]
    capture = FakeCapture(frames, fps=0)
    service, _detector = build_service(db_session, tmp_path, capture)

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="invalid.mp4",
        content=b"video",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=5,
        max_frames=50,
    )
    db_session.expire_all()
    status = service.get_status(db_session, user.id, submission.task_id)

    assert status["status"] == "failed"
    assert status["error"] == "视频元数据无效，无法开始检测"


def test_video_queue_has_bounded_admission_and_safe_shutdown(db_session, tmp_path):
    user = create_user(db_session, "video_queue_user")
    executor = DeferredExecutor()
    frames = [np.zeros((24, 32, 3), dtype=np.uint8)]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
        executor=executor,
        max_pending_tasks=1,
    )

    service.submit(
        db=db_session,
        user_id=user.id,
        filename="one.mp4",
        content=b"one",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=1,
        max_frames=1,
    )
    with pytest.raises(VideoQueueFullError):
        service.submit(
            db=db_session,
            user_id=user.id,
            filename="two.mp4",
            content=b"two",
            confidence=0.25,
            iou=0.45,
            image_size=640,
            sample_rate=1,
            max_frames=1,
        )
    assert db_session.query(DetectionTask).filter(
        DetectionTask.user_id == user.id
    ).count() == 1

    executor.run_all()
    service.shutdown()
    assert executor.shutdown_options == {"wait": True, "cancel_futures": False}


def test_terminal_progress_expires_and_reloads_complete_sidecar(
    db_session, tmp_path
):
    user = create_user(db_session, "video_sidecar_user")
    clock_value = [10.0]
    registry = VideoProgressRegistry(ttl_seconds=1, clock=lambda: clock_value[0])
    frames = [np.zeros((24, 32, 3), dtype=np.uint8)]
    capture = FakeCapture(frames)
    service, detector = build_service(
        db_session,
        tmp_path,
        capture,
        detections=False,
        progress_registry=registry,
    )

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="empty.mp4",
        content=b"video",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=1,
        max_frames=1,
    )
    clock_value[0] = 12.0
    assert registry.get(submission.task_id) is None

    reloaded = VideoDetectionService(
        detector=detector,
        task_service=service.task_service,
        session_factory=service.session_factory,
        output_dir=tmp_path / "detections",
        temp_dir=tmp_path / "videos",
        status_dir=tmp_path / "video-status",
        capture_factory=lambda _path: capture,
        executor=ImmediateExecutor(),
        progress_registry=VideoProgressRegistry(),
    ).get_status(db_session, user.id, submission.task_id)

    assert reloaded["filename"] == "empty.mp4"
    assert reloaded["metadata"]["fps"] == 10.0
    assert len(reloaded["key_frames"]) == 1
    assert reloaded["key_frames"][0]["traffic_signs"] == []
    assert (tmp_path / "video-status" / f"{submission.task_id}.json").is_file()
    assert not (
        tmp_path
        / "detections"
        / str(submission.task_id)
        / "video_status.json"
    ).exists()


def test_worker_hides_detector_filesystem_errors(db_session, tmp_path):
    user = create_user(db_session, "video_worker_error_user")
    frames = [np.zeros((24, 32, 3), dtype=np.uint8)]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
        failure=ModelUnavailableError("missing D:/secret/best.pt"),
    )

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="road.mp4",
        content=b"video",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=1,
        max_frames=1,
    )
    status = service.get_status(db_session, user.id, submission.task_id)

    assert status["status"] == "failed"
    assert status["error"] == "视频检测失败，请查看服务日志"
    assert "D:/secret" not in status["error"]


def test_progress_uses_planned_sample_window_when_max_frames_truncates_video():
    assert VideoDetectionService._planned_source_frames(
        total_frames=1000,
        sample_rate=5,
        max_frames=2,
    ) == 6


def test_executor_submission_failure_marks_task_failed_and_cleans_files(
    db_session, tmp_path
):
    user = create_user(db_session, "video_submit_failure_user")
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
        executor=FailingExecutor(),
    )

    with pytest.raises(Exception, match="无法创建视频检测任务"):
        service.submit(
            db=db_session,
            user_id=user.id,
            filename="road.mp4",
            content=b"video",
            confidence=0.25,
            iou=0.45,
            image_size=640,
            sample_rate=1,
            max_frames=1,
        )
    db_session.expire_all()
    task = (
        db_session.query(DetectionTask)
        .filter(DetectionTask.user_id == user.id)
        .one()
    )

    assert task.status == "failed"
    assert task.error_message == "无法创建视频检测任务，请稍后重试"
    assert list((tmp_path / "videos").glob("**/*")) == []


def test_compensation_database_failure_still_cleans_source_files(
    db_session, tmp_path
):
    user = create_user(db_session, "video_compensation_failure_user")
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
        executor=FailingExecutor(),
    )
    failing_db = CompensationCommitFailingSession(db_session, fail_on_commit=3)

    with pytest.raises(Exception, match="无法创建视频检测任务"):
        service.submit(
            db=failing_db,
            user_id=user.id,
            filename="road.mp4",
            content=b"video",
            confidence=0.25,
            iou=0.45,
            image_size=640,
            sample_rate=1,
            max_frames=1,
        )

    assert list((tmp_path / "videos").glob("**/*")) == []


def test_migrates_legacy_public_sidecars_to_private_directory(
    db_session, tmp_path
):
    capture = FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)])
    service, _detector = build_service(db_session, tmp_path, capture)
    legacy_dir = tmp_path / "detections" / "123"
    legacy_dir.mkdir(parents=True)
    legacy = legacy_dir / "video_status.json"
    legacy.write_text('{"task_id":123,"status":"completed"}', encoding="utf-8")

    migrated = service.migrate_legacy_sidecars()

    assert migrated == 1
    assert not legacy.exists()
    assert (
        tmp_path / "video-status" / "123.json"
    ).read_text(encoding="utf-8") == '{"task_id":123,"status":"completed"}'


def test_legacy_sidecar_migration_failure_blocks_startup(
    db_session, tmp_path, monkeypatch
):
    capture = FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)])
    service, _detector = build_service(db_session, tmp_path, capture)
    legacy_dir = tmp_path / "detections" / "124"
    legacy_dir.mkdir(parents=True)
    legacy = legacy_dir / "video_status.json"
    legacy.write_text('{"task_id":124}', encoding="utf-8")
    monkeypatch.setattr(
        "app.services.video_detection_service.shutil.move",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(PermissionError("locked")),
    )

    with pytest.raises(VideoStatusMigrationError):
        service.migrate_legacy_sidecars()

    assert legacy.exists()
