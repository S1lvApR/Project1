from concurrent.futures import Future
from types import SimpleNamespace

import cv2
import numpy as np
import pytest
from sqlalchemy.orm import sessionmaker

from app.entity.db_models import DetectionResult, DetectionTask, User
from app.services.detection_task_service import DetectionTaskService
from app.services.video_detection_service import (
    VideoDetectionService,
    VideoProgressRegistry,
    VideoQueueFullError,
    VideoStatusMigrationError,
    build_inference_schedule,
)
from app.services.yolo_detector import (
    DetectedObject,
    ModelUnavailableError,
    VideoFramePrediction,
)


def test_inference_schedule_covers_full_timeline_when_budget_is_limited():
    schedule = build_inference_schedule(
        3394,
        sample_rate=1,
        max_frames=50,
    )

    assert len(schedule) == 50
    assert schedule[0] == 0
    assert schedule[-1] == 3393
    assert all(left < right for left, right in zip(schedule, schedule[1:]))


def test_zero_budget_and_unit_stride_select_every_frame():
    assert build_inference_schedule(
        6,
        sample_rate=1,
        max_frames=0,
    ) == (0, 1, 2, 3, 4, 5)


def test_explicit_stride_still_includes_final_frame():
    assert build_inference_schedule(
        8,
        sample_rate=3,
        max_frames=0,
    ) == (0, 3, 6, 7)


@pytest.mark.parametrize("total_frames", [0, -1])
def test_inference_schedule_is_empty_without_source_frames(total_frames):
    assert build_inference_schedule(
        total_frames,
        sample_rate=1,
        max_frames=0,
    ) == ()


@pytest.mark.parametrize(
    ("sample_rate", "max_frames"),
    [(0, 1), (-1, 1), (1, -1)],
)
def test_inference_schedule_rejects_invalid_options(sample_rate, max_frames):
    with pytest.raises(ValueError):
        build_inference_schedule(
            10,
            sample_rate=sample_rate,
            max_frames=max_frames,
        )


def test_inference_schedule_returns_all_candidates_with_sufficient_budget():
    assert build_inference_schedule(
        8,
        sample_rate=3,
        max_frames=4,
    ) == (0, 3, 6, 7)


def test_single_frame_budget_selects_final_source_frame():
    assert build_inference_schedule(
        8,
        sample_rate=3,
        max_frames=1,
    ) == (7,)


def test_inference_schedule_uses_uniform_candidate_positions():
    assert build_inference_schedule(
        11,
        sample_rate=1,
        max_frames=4,
    ) == (0, 3, 7, 10)


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

    def __init__(
        self,
        model_path,
        detections=True,
        failure=None,
        class_name="pl60",
        class_name_sequence=None,
    ):
        self.model_path = model_path
        self.calls = []
        self.with_detections = detections
        self.failure = failure
        self.class_name = class_name
        self.class_name_sequence = tuple(class_name_sequence or ())
        class_ids = {
            "pl60": 29,
            "pl80": 31,
            "pm55": 34,
        }
        self.class_id = class_ids[class_name]
        self.class_names = {
            class_ids[name]: name
            for name in ({class_name} | set(self.class_name_sequence))
        }

    def predict_video_frame(
        self,
        frame,
        *,
        confidence,
        iou,
        image_size,
        device=None,
    ):
        if self.failure is not None:
            raise self.failure
        height, width = frame.shape[:2]
        call_index = len(self.calls)
        class_name = (
            self.class_name_sequence[call_index]
            if call_index < len(self.class_name_sequence)
            else self.class_name
        )
        class_id = {
            "pl60": 29,
            "pl80": 31,
            "pm55": 34,
        }[class_name]
        self.calls.append(
            {
                "frame_index": int(frame[0, 0, 0]),
                "confidence": confidence,
                "iou": iou,
                "image_size": image_size,
                "device": device,
            }
        )
        return VideoFramePrediction(
            width=width,
            height=height,
            inference_time_ms=8.0,
            detections=(
                DetectedObject(
                    class_id=class_id,
                    class_name=class_name,
                    confidence=0.9,
                    bbox=(1.0, 2.0, 12.0, 14.0),
                ),
            ) if self.with_detections else (),
        )


class FakeSpeedClassifier:
    def __init__(self, class_id=2, confidence=0.99):
        self.class_id = class_id
        self.confidence = confidence
        self.calls = []

    def predict(self, image_bytes, *, image_size, **_kwargs):
        self.calls.append({"image_bytes": image_bytes, "image_size": image_size})
        return SimpleNamespace(
            detections=(
                DetectedObject(
                    class_id=self.class_id,
                    class_name="Speed limit (50 km/h)",
                    confidence=self.confidence,
                    bbox=(0.0, 0.0, 1.0, 1.0),
                ),
            )
        )


class FakeVideoEncoder:
    def __init__(self, *, output_path, width, height, fps, failure=None):
        self.output_path = output_path
        self.width = width
        self.height = height
        self.fps = fps
        self.failure = failure
        self.frames = []
        self.opened = False
        self.aborted = False

    def open(self):
        self.opened = True

    def write(self, frame):
        self.frames.append(frame.copy())

    def close(self):
        if self.failure is not None:
            raise self.failure
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.output_path.write_bytes(b"fake-mp4")
        return self.output_path

    def abort(self):
        self.aborted = True
        self.output_path.unlink(missing_ok=True)


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
    encoder_failure=None,
    progress_registry=None,
    detected_class_name="pl60",
    detected_class_names=None,
):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    detector = FakeRealtimeDetector(
        model_path,
        detections=detections,
        failure=failure,
        class_name=detected_class_name,
        class_name_sequence=detected_class_names,
    )
    task_service = DetectionTaskService(
        detector=detector,
        output_dir=tmp_path / "detections",
    )
    encoders = []

    def encoder_factory(**options):
        encoder = FakeVideoEncoder(**options, failure=encoder_failure)
        encoders.append(encoder)
        return encoder

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
        encoder_factory=encoder_factory,
        preview_interval_frames=2,
        key_frame_interval_seconds=0,
    )
    service.fake_encoders = encoders
    return service, detector


def test_video_task_processes_full_timeline_and_returns_playable_media(
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
    assert status["stage"] == "completed"
    assert status["processed_frames"] == 6
    assert status["inference_frames"] == 3
    assert status["sampled_frames"] == 3
    assert status["detected_frames"] == 3
    assert [call["frame_index"] for call in detector.calls] == [0, 4, 5]
    assert [frame["frame_index"] for frame in status["key_frames"]] == [0, 4, 5]
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
    assert len(service.fake_encoders) == 1
    assert len(service.fake_encoders[0].frames) == 6
    assert status["preview_frame_url"].endswith("/preview.jpg")
    assert status["preview_version"] == 5
    assert status["annotated_video_url"].endswith("/road_annotated.mp4")
    assert status["download_url"] == status["annotated_video_url"]
    assert (
        tmp_path / "detections" / str(submission.task_id) / "preview.jpg"
    ).is_file()
    assert (
        tmp_path / "detections" / str(submission.task_id) / "road_annotated.mp4"
    ).read_bytes() == b"fake-mp4"
    assert capture.released is True
    assert list((tmp_path / "videos").glob("**/*")) == []


def test_video_task_refines_speed_limit_digits_before_persisting_results(
    db_session, tmp_path
):
    user = create_user(db_session, "video_speed_refinement_user")
    frames = [np.zeros((24, 32, 3), dtype=np.uint8)]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
        detected_class_name="pl80",
    )
    classifier = FakeSpeedClassifier(class_id=2, confidence=0.99)
    service.speed_classifier = classifier
    service.speed_refinement_enabled = True
    service.speed_refinement_min_confidence = 0.9
    service.speed_refinement_padding_ratio = 0.25

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="speed-50.mp4",
        content=b"fake-video",
        confidence=0.3,
        iou=0.5,
        image_size=1280,
        sample_rate=1,
        max_frames=0,
    )
    db_session.expire_all()
    status = service.get_status(db_session, user.id, submission.task_id)
    record = (
        db_session.query(DetectionResult)
        .filter(DetectionResult.task_id == submission.task_id)
        .one()
    )

    sign = status["key_frames"][0]["traffic_signs"][0]
    assert sign["class_name"] == "pl50"
    assert sign["display_name"] == "最高限速 50 km/h"
    assert record.class_name == "pl50"
    assert len(classifier.calls) == 1
    assert classifier.calls[0]["image_size"] == 128


@pytest.mark.parametrize(
    ("source_name", "source_class_id"),
    [
        ("pl40", 26),
        ("pl70", 30),
        ("pl80", 31),
        ("pl100", 22),
        ("pr40", 38),
    ],
)
def test_speed_refinement_corrects_validated_limit_50_confusions(
    db_session,
    tmp_path,
    source_name,
    source_class_id,
):
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
    )
    service.speed_classifier = FakeSpeedClassifier(
        class_id=2,
        confidence=0.99,
    )
    service.speed_refinement_enabled = True
    source = (
        DetectedObject(
            class_id=source_class_id,
            class_name=source_name,
            confidence=0.57,
            bbox=(1.0, 2.0, 12.0, 14.0),
        ),
    )

    refined = service._refine_speed_limit_detections(
        np.zeros((24, 32, 3), dtype=np.uint8),
        source,
    )

    assert refined[0].class_name == "pl50"
    assert refined[0].class_id == 28
    assert refined[0].confidence == source[0].confidence


def test_speed_refinement_uses_calibrated_pl40_threshold(
    db_session, tmp_path
):
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
    )
    service.speed_classifier = FakeSpeedClassifier(
        class_id=2,
        confidence=0.755,
    )
    service.speed_refinement_enabled = True
    service.speed_refinement_min_confidence = 0.9
    service.speed_refinement_pl40_min_confidence = 0.75
    source = (
        DetectedObject(
            class_id=26,
            class_name="pl40",
            confidence=0.29,
            bbox=(1.0, 2.0, 12.0, 14.0),
        ),
    )

    refined = service._refine_speed_limit_detections(
        np.zeros((24, 32, 3), dtype=np.uint8),
        source,
    )

    assert refined[0].class_name == "pl50"


def test_speed_refinement_preserves_low_confidence_and_non_speed_results(
    db_session, tmp_path
):
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
    )
    classifier = FakeSpeedClassifier(class_id=2, confidence=0.79)
    service.speed_classifier = classifier
    service.speed_refinement_enabled = True
    service.speed_refinement_min_confidence = 0.8
    source = (
        DetectedObject(
            class_id=31,
            class_name="pl80",
            confidence=0.57,
            bbox=(1.0, 2.0, 12.0, 14.0),
        ),
        DetectedObject(
            class_id=8,
            class_name="p10",
            confidence=0.9,
            bbox=(15.0, 2.0, 25.0, 14.0),
        ),
    )

    refined = service._refine_speed_limit_detections(
        np.zeros((24, 32, 3), dtype=np.uint8),
        source,
    )

    assert refined == source
    assert len(classifier.calls) == 1


def test_speed_refinement_does_not_replace_valid_speed_with_another_gtsrb_class(
    db_session, tmp_path
):
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture([np.zeros((24, 32, 3), dtype=np.uint8)]),
    )
    service.speed_classifier = FakeSpeedClassifier(class_id=5, confidence=0.99)
    service.speed_refinement_enabled = True
    source = (
        DetectedObject(
            class_id=22,
            class_name="pl100",
            confidence=0.82,
            bbox=(1.0, 2.0, 12.0, 14.0),
        ),
    )

    refined = service._refine_speed_limit_detections(
        np.zeros((24, 32, 3), dtype=np.uint8),
        source,
    )

    assert refined == source


def test_video_task_propagates_confirmed_limit_50_to_adjacent_weight_confusion(
    db_session, tmp_path
):
    user = create_user(db_session, "video_speed_tracking_user")
    frames = [
        np.zeros((24, 32, 3), dtype=np.uint8),
        np.ones((24, 32, 3), dtype=np.uint8),
    ]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
        detected_class_name="pl80",
        detected_class_names=("pl80", "pm55"),
    )
    classifier = FakeSpeedClassifier(class_id=2, confidence=0.99)
    service.speed_classifier = classifier
    service.speed_refinement_enabled = True
    service.speed_refinement_min_confidence = 0.9

    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="speed-track.mp4",
        content=b"fake-video",
        confidence=0.3,
        iou=0.5,
        image_size=1280,
        sample_rate=1,
        max_frames=0,
    )
    db_session.expire_all()
    status = service.get_status(db_session, user.id, submission.task_id)

    assert [
        frame["traffic_signs"][0]["class_name"]
        for frame in status["key_frames"]
    ] == ["pl50", "pl50"]
    assert len(classifier.calls) == 1


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
    assert reloaded["stage"] == "completed"
    assert reloaded["inference_frames"] == 1
    assert reloaded["key_frames"] == []
    assert reloaded["annotated_video_url"].endswith("/empty_annotated.mp4")
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


def test_video_encoder_failure_marks_task_failed_and_cleans_partial_outputs(
    db_session,
    tmp_path,
):
    user = create_user(db_session, "video_encoder_failure_user")
    frames = [np.full((24, 32, 3), value, dtype=np.uint8) for value in range(3)]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
        encoder_failure=RuntimeError("ffmpeg failed"),
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
        max_frames=0,
    )
    status = service.get_status(db_session, user.id, submission.task_id)

    assert status["status"] == "failed"
    assert status["stage"] == "failed"
    assert service.fake_encoders[0].aborted is True
    assert not (tmp_path / "detections" / str(submission.task_id)).exists()
    assert (
        db_session.query(DetectionResult)
        .filter(DetectionResult.task_id == submission.task_id)
        .count()
        == 0
    )


def test_database_fallback_exposes_new_video_status_fields(db_session, tmp_path):
    user = create_user(db_session, "video_database_fallback_user")
    frames = [np.full((24, 32, 3), value, dtype=np.uint8) for value in range(2)]
    service, _detector = build_service(
        db_session,
        tmp_path,
        FakeCapture(frames),
    )
    submission = service.submit(
        db=db_session,
        user_id=user.id,
        filename="fallback.mp4",
        content=b"video",
        confidence=0.25,
        iou=0.45,
        image_size=640,
        sample_rate=1,
        max_frames=0,
    )
    db_session.expire_all()
    task = db_session.get(DetectionTask, submission.task_id)

    fallback = service._persisted_status(task)

    assert fallback["stage"] == "completed"
    assert fallback["inference_frames"] == 2
    assert fallback["detected_frames"] == 2
    assert fallback["preview_frame_url"].endswith("/preview.jpg")
    assert fallback["annotated_video_url"].endswith(
        "/fallback_annotated.mp4"
    )
    assert fallback["download_url"] == fallback["annotated_video_url"]


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
