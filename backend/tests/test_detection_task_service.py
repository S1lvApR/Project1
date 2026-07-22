from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image

from app.entity.db_models import (
    DetectionTask,
    DetectionResult,
    DetectionScene,
    ModelVersion,
    User,
)
from app.services.detection_task_service import (
    DetectionInput,
    DetectionTaskService,
    TaskNotFoundError,
)
from app.services.yolo_detector import (
    DetectedObject,
    ImagePrediction,
    InvalidImageError,
    ModelUnavailableError,
)
from app.services.recognition_router import LocalRecognitionRouter


class FakeDetector:
    model_path = Path("D:/models/best.pt")
    selected_device = "0"
    class_names = {0: "p10", 1: "pl60"}

    def predict(self, image_bytes, confidence, iou, image_size):
        if image_bytes == b"bad":
            raise InvalidImageError("Unable to decode uploaded image")
        if image_bytes == b"missing-model":
            raise ModelUnavailableError("checkpoint unavailable")
        return ImagePrediction(
            width=32,
            height=24,
            inference_time_ms=12.5,
            detections=(
                DetectedObject(
                    class_id=1,
                    class_name="pl60",
                    confidence=0.91,
                    bbox=(1.0, 2.0, 20.0, 22.0),
                ),
            ),
            annotated_jpeg=b"annotated-jpeg",
        )


class FakeAliasDetector:
    model_path = Path("D:/models/alias-best.pt")
    selected_device = "0"
    class_names = {0: "i160", 1: "unknown"}


class FakeClassifier:
    model_path = Path("D:/models/gtsrb-best.pt")
    selected_device = "0"
    class_names = {16: "Vehicles over 3.5 metric tons prohibited"}

    def predict(self, image_bytes, confidence, iou, image_size):
        del confidence, iou, image_size
        with Image.open(BytesIO(image_bytes)) as image:
            width, height = image.size
        return ImagePrediction(
            width=width,
            height=height,
            inference_time_ms=4.5,
            detections=(
                DetectedObject(
                    class_id=16,
                    class_name="Vehicles over 3.5 metric tons prohibited",
                    confidence=0.975,
                    bbox=(0.0, 0.0, float(width), float(height)),
                ),
            ),
            annotated_jpeg=b"classified-jpeg",
        )


def make_jpeg(width=53, height=54):
    output = BytesIO()
    Image.new("RGB", (width, height), color="white").save(output, format="JPEG")
    return output.getvalue()


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


def test_run_task_registers_model_persists_results_and_writes_annotation(
    db_session, tmp_path
):
    user = create_user(db_session, "detector_service_user")
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)

    outcome = service.run_task(
        db=db_session,
        user_id=user.id,
        images=[DetectionInput(filename="road.jpg", content=b"image")],
        task_type="single",
        confidence=0.25,
        iou=0.45,
        image_size=640,
    )

    assert outcome.task.status == "completed"
    assert outcome.task.total_images == 1
    assert outcome.task.total_objects == 1
    assert outcome.task.total_inference_time == 12.5
    assert outcome.device == "0"
    assert outcome.images[0]["traffic_signs"][0]["type"] == "pl60"
    assert outcome.images[0]["traffic_signs"][0]["class_name"] == "pl60"
    assert outcome.images[0]["traffic_signs"][0]["class_name_cn"] == "最高限速 60 km/h"
    assert outcome.images[0]["traffic_signs"][0]["display_name"] == "最高限速 60 km/h"
    assert outcome.images[0]["annotated_image_url"].startswith(
        "/uploads/detections/"
    )
    assert (tmp_path / str(outcome.task.id)).is_dir()
    assert list((tmp_path / str(outcome.task.id)).glob("*.jpg"))
    assert (
        db_session.query(DetectionResult)
        .filter_by(task_id=outcome.task.id)
        .count()
        == 1
    )
    assert (
        db_session.query(DetectionScene)
        .filter_by(name="tt100k_traffic_signs")
        .count()
        == 1
    )
    scene = db_session.query(DetectionScene).filter_by(name="tt100k_traffic_signs").one()
    assert scene.class_names_cn["pl60"] == "最高限速 60 km/h"
    record = db_session.query(DetectionResult).filter_by(task_id=outcome.task.id).one()
    assert record.class_name == "pl60"
    assert record.class_name_cn == "最高限速 60 km/h"
    assert db_session.query(ModelVersion).filter_by(is_default=True).count() == 1


def test_detector_scene_labels_only_include_active_classes(db_session, tmp_path):
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)

    scene, _ = service.ensure_registry(db_session)

    assert scene.class_names == ["p10", "pl60"]
    assert scene.class_names_cn == {
        "p10": "禁止小型客车驶入",
        "pl60": "最高限速 60 km/h",
    }


def test_ensure_registry_preserves_existing_classification_scene_labels(
    db_session, tmp_path
):
    service = DetectionTaskService(output_dir=tmp_path)

    scene, _ = service.ensure_registry(
        db_session,
        predictor=FakeClassifier(),
        recognition_mode="classify",
    )
    scene.class_names_cn = {"legacy": "保留"}
    db_session.commit()

    refreshed_scene, _ = service.ensure_registry(
        db_session,
        predictor=FakeClassifier(),
        recognition_mode="classify",
    )

    assert refreshed_scene.id == scene.id
    assert refreshed_scene.class_names == [
        "Vehicles over 3.5 metric tons prohibited"
    ]
    assert refreshed_scene.class_names_cn == {"legacy": "保留"}


def test_ensure_registry_repairs_stale_detector_scene_labels(db_session, tmp_path):
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)
    scene, _ = service.ensure_registry(db_session)
    scene.class_names_cn = {"stale": "stale"}
    db_session.commit()

    refreshed_scene, _ = service.ensure_registry(db_session)

    assert refreshed_scene.class_names == ["p10", "pl60"]
    assert refreshed_scene.class_names_cn == {
        "p10": "禁止小型客车驶入",
        "pl60": "最高限速 60 km/h",
    }


def test_detector_scene_labels_preserve_aliases_and_omit_unknowns(
    db_session, tmp_path
):
    service = DetectionTaskService(
        detector=FakeAliasDetector(),
        output_dir=tmp_path,
    )

    scene, _ = service.ensure_registry(db_session)

    assert scene.class_names == ["i160", "unknown"]
    assert scene.class_names_cn == {"i160": "最低限速 60 km/h"}


def test_partial_batch_failure_completes_with_error_summary(db_session, tmp_path):
    user = create_user(db_session, "detector_partial_user")
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)

    outcome = service.run_task(
        db=db_session,
        user_id=user.id,
        images=[
            DetectionInput(filename="valid.jpg", content=b"image"),
            DetectionInput(filename="broken.jpg", content=b"bad"),
        ],
        task_type="batch",
        confidence=0.25,
        iou=0.45,
        image_size=640,
    )

    assert outcome.task.status == "completed"
    assert outcome.task.total_images == 2
    assert outcome.task.total_objects == 1
    assert outcome.images[1]["success"] is False
    assert "decode" in outcome.images[1]["error"]
    assert "broken.jpg" in outcome.task.error_message


def test_model_failure_marks_task_failed_before_reraising(db_session, tmp_path):
    user = create_user(db_session, "detector_model_failure_user")
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)

    with pytest.raises(ModelUnavailableError, match="checkpoint unavailable"):
        service.run_task(
            db=db_session,
            user_id=user.id,
            images=[DetectionInput(filename="model.jpg", content=b"missing-model")],
            task_type="single",
            confidence=0.25,
            iou=0.45,
            image_size=640,
        )

    task = db_session.query(DetectionTask).filter_by(user_id=user.id).one()
    assert task.status == "failed"
    assert "checkpoint unavailable" in task.error_message


def test_task_queries_are_scoped_to_owner(db_session, tmp_path):
    owner = create_user(db_session, "detector_owner_user")
    other_user = create_user(db_session, "detector_other_user")
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)
    outcome = service.run_task(
        db=db_session,
        user_id=owner.id,
        images=[DetectionInput(filename="road.jpg", content=b"image")],
        task_type="single",
        confidence=0.25,
        iou=0.45,
        image_size=640,
    )

    assert service.list_tasks(db_session, owner.id)[0].id == outcome.task.id
    with pytest.raises(TaskNotFoundError):
        service.get_task(db_session, other_user.id, outcome.task.id)


def test_auto_mode_persists_gtsrb_classification(db_session, tmp_path):
    user = create_user(db_session, "classifier_service_user")
    router = LocalRecognitionRouter(
        detector=FakeDetector(),
        classifier=FakeClassifier(),
        crop_max_dimension=512,
        classification_image_size=128,
    )
    service = DetectionTaskService(router=router, output_dir=tmp_path)

    outcome = service.run_task(
        db=db_session,
        user_id=user.id,
        images=[DetectionInput(filename="00000.png", content=make_jpeg())],
        task_type="single",
        confidence=0.25,
        iou=0.45,
        image_size=1280,
        mode="auto",
    )

    result = outcome.images[0]
    assert result["recognition_mode"] == "classify"
    assert result["result_type"] == "classification"
    assert result["dataset"] == "gtsrb"
    assert result["traffic_signs"][0]["class_id"] == 16
    assert result["traffic_signs"][0]["bbox"] == [0.0, 0.0, 53.0, 54.0]
    assert result["traffic_signs"][0]["display_name"] == "禁止 3.5 吨以上车辆通行"
    record = db_session.query(DetectionResult).filter_by(task_id=outcome.task.id).one()
    assert record.class_id == 16
    assert record.bbox == [0.0, 0.0, 53.0, 54.0]
    assert outcome.model_version.model_name == "gtsrb-yolo11n-cls"
