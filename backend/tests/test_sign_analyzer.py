from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

from PIL import Image

from app.api import sign_analyzer
from app.services.detection_task_service import DetectionTaskService
from app.services.yolo_detector import DetectedObject, ImagePrediction
from app.services.yolo_detector import InvalidImageError


class FakeDetector:
    model_path = Path("D:/models/best.pt")
    selected_device = "0"
    class_names = {0: "p10", 1: "pl60"}

    def predict(self, image_bytes, confidence, iou, image_size):
        try:
            Image.open(BytesIO(image_bytes)).verify()
        except Exception as exc:
            raise InvalidImageError("Unable to decode uploaded image") from exc
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


def make_jpeg():
    output = BytesIO()
    Image.new("RGB", (32, 24), color="white").save(output, format="JPEG")
    return output.getvalue()


def authenticate(client, username):
    client.post(
        "/api/auth/register",
        json={
            "username": username,
            "email": f"{username}@example.com",
            "password": "123456",
        },
    )
    login = client.post(
        "/api/auth/login",
        json={"username": username, "password": "123456"},
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


def install_fake_service(monkeypatch, tmp_path):
    service = DetectionTaskService(detector=FakeDetector(), output_dir=tmp_path)
    monkeypatch.setattr(sign_analyzer, "detection_task_service", service, raising=False)

    class LegacyStub:
        @staticmethod
        def store_file(*_args, **_kwargs):
            return None

        @staticmethod
        def save_image_to_temp(*_args, **_kwargs):
            return "legacy-temp"

        @staticmethod
        def analyze_from_temp(*_args, **_kwargs):
            return {
                "success": True,
                "error": None,
                "traffic_signs": [],
                "traffic_lights": [],
            }

        @staticmethod
        def batch_analyze(image_list):
            return {
                "total_images": len(image_list),
                "total_signs": 0,
                "total_lights": 0,
                "results": [],
            }

        @staticmethod
        def delete_temp_image(*_args, **_kwargs):
            return None

        @staticmethod
        def extract_zip(*_args, **_kwargs):
            return [], []

    monkeypatch.setattr(
        sign_analyzer, "sign_analyzer_service", LegacyStub(), raising=False
    )
    return service


def test_single_image_creates_real_detection_task(client, monkeypatch, tmp_path):
    install_fake_service(monkeypatch, tmp_path)
    headers = authenticate(client, "sign_single_user")

    response = client.post(
        "/api/sign-analyzer/analyze",
        headers=headers,
        files={"image": ("road.jpg", make_jpeg(), "image/jpeg")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["success"] is True
    assert payload["data"]["task_id"] > 0
    assert payload["data"]["traffic_signs"][0]["type"] == "pl60"
    assert payload["data"]["traffic_lights"] == []
    assert payload["data"]["annotated_image_url"].startswith(
        "/uploads/detections/"
    )
    assert payload["data"]["model"]["device"] == "0"


def test_sign_analyzer_requires_authentication(client):
    response = client.post(
        "/api/sign-analyzer/analyze",
        files={"image": ("road.jpg", make_jpeg(), "image/jpeg")},
    )

    assert response.status_code == 401


def test_single_image_rejects_unsupported_and_corrupt_files(
    client, monkeypatch, tmp_path
):
    install_fake_service(monkeypatch, tmp_path)
    headers = authenticate(client, "sign_invalid_user")

    unsupported = client.post(
        "/api/sign-analyzer/analyze",
        headers=headers,
        files={"image": ("road.txt", b"text", "text/plain")},
    )
    corrupt = client.post(
        "/api/sign-analyzer/analyze",
        headers=headers,
        files={"image": ("road.jpg", b"not-an-image", "image/jpeg")},
    )

    assert unsupported.status_code == 400
    assert corrupt.status_code == 400


def test_batch_response_keeps_compatibility_totals(client, monkeypatch, tmp_path):
    install_fake_service(monkeypatch, tmp_path)
    headers = authenticate(client, "sign_batch_user")

    response = client.post(
        "/api/sign-analyzer/batch",
        headers=headers,
        files=[
            ("files", ("one.jpg", make_jpeg(), "image/jpeg")),
            ("files", ("two.jpg", make_jpeg(), "image/jpeg")),
        ],
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["data"]["total_images"] == 2
    assert payload["data"]["total_signs"] == 2
    assert payload["data"]["total_lights"] == 0
    assert len(payload["data"]["results"]) == 2
    assert payload["data"]["task_id"] > 0


def test_inference_parameters_are_bounded(client, monkeypatch, tmp_path):
    install_fake_service(monkeypatch, tmp_path)
    headers = authenticate(client, "sign_parameter_user")

    response = client.post(
        "/api/sign-analyzer/analyze",
        headers=headers,
        data={"confidence": "1.5", "iou": "0.45", "image_size": "640"},
        files={"image": ("road.jpg", make_jpeg(), "image/jpeg")},
    )

    assert response.status_code == 400


def test_recognition_mode_is_validated(client, monkeypatch, tmp_path):
    install_fake_service(monkeypatch, tmp_path)
    headers = authenticate(client, "sign_mode_user")

    response = client.post(
        "/api/sign-analyzer/analyze",
        headers=headers,
        data={"mode": "unknown"},
        files={"image": ("road.jpg", make_jpeg(), "image/jpeg")},
    )

    assert response.status_code == 400


def test_task_list_and_detail_are_scoped_to_authenticated_user(
    client, monkeypatch, tmp_path
):
    install_fake_service(monkeypatch, tmp_path)
    owner_headers = authenticate(client, "sign_task_owner")
    other_headers = authenticate(client, "sign_task_other")
    create_response = client.post(
        "/api/sign-analyzer/analyze",
        headers=owner_headers,
        files={"image": ("road.jpg", make_jpeg(), "image/jpeg")},
    )
    task_id = create_response.json()["data"]["task_id"]

    task_list = client.get("/api/sign-analyzer/tasks", headers=owner_headers)
    detail = client.get(
        f"/api/sign-analyzer/tasks/{task_id}", headers=owner_headers
    )
    hidden = client.get(
        f"/api/sign-analyzer/tasks/{task_id}", headers=other_headers
    )

    assert task_list.status_code == 200
    assert task_list.json()["data"][0]["id"] == task_id
    assert detail.status_code == 200
    assert detail.json()["data"]["task"]["id"] == task_id
    assert detail.json()["data"]["task"]["recognition_mode"] == "detect"
    assert detail.json()["data"]["task"]["result_type"] == "detection"
    assert detail.json()["data"]["task"]["dataset"] == "tt100k"
    assert detail.json()["data"]["task"]["model_family"] == "tt100k-detector"
    persisted_result = detail.json()["data"]["results"][0]
    assert persisted_result["class_name"] == "pl60"
    assert persisted_result["class_name_cn"] == "最高限速 60 km/h"
    assert persisted_result["display_name"] == "最高限速 60 km/h"
    assert persisted_result["recognition_mode"] == "detect"
    assert persisted_result["result_type"] == "detection"
    assert persisted_result["dataset"] == "tt100k"
    assert persisted_result["model_family"] == "tt100k-detector"
    assert hidden.status_code == 404


def test_persisted_classifier_result_exposes_routing_metadata():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolo11n-cls")
        ),
        image_path="00000.png",
        annotated_image_url="/uploads/detections/2/0000_00000.jpg",
        class_name="Vehicles over 3.5 metric tons prohibited",
        class_name_cn="禁止 3.5 吨以上车辆通行",
        class_id=16,
        confidence=1.0,
        bbox=[0.0, 0.0, 48.0, 48.0],
        inference_time=2.0,
        image_width=48,
        image_height=48,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["recognition_mode"] == "classify"
    assert payload["result_type"] == "classification"
    assert payload["dataset"] == "gtsrb"
    assert payload["model_family"] == "gtsrb-classifier"
    assert payload["display_name"] == payload["class_name_cn"]


def test_persisted_classifier_result_derives_missing_chinese_name_from_tt100k_lookup():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolo11n-cls")
        ),
        image_path="00000.png",
        annotated_image_url="/uploads/detections/2/0000_00000.jpg",
        class_name="p23",
        class_name_cn=None,
        class_id=16,
        confidence=1.0,
        bbox=[0.0, 0.0, 48.0, 48.0],
        inference_time=2.0,
        image_width=48,
        image_height=48,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["recognition_mode"] == "classify"
    assert payload["result_type"] == "classification"
    assert payload["dataset"] == "gtsrb"
    assert payload["model_family"] == "gtsrb-classifier"
    assert payload["class_name"] == "p23"
    assert payload["class_name_cn"] == "禁止向左转弯"
    assert payload["display_name"] == "禁止向左转弯"


def test_persisted_classifier_result_preserves_existing_chinese_name_for_unknown_code():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolo11n-cls")
        ),
        image_path="00000.png",
        annotated_image_url="/uploads/detections/2/0000_00000.jpg",
        class_name="unknown-code",
        class_name_cn="保持原文",
        class_id=16,
        confidence=1.0,
        bbox=[0.0, 0.0, 48.0, 48.0],
        inference_time=2.0,
        image_width=48,
        image_height=48,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["class_name_cn"] == "保持原文"
    assert payload["display_name"] == "保持原文"
    assert payload["dataset"] == "gtsrb"


def test_persisted_tt100k_result_derives_missing_chinese_name():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolov11s")
        ),
        image_path="00000.png",
        annotated_image_url="/uploads/detections/2/0000_00000.jpg",
        class_name="p23",
        class_name_cn=None,
        class_id=12,
        confidence=1.0,
        bbox=[0.0, 0.0, 48.0, 48.0],
        inference_time=2.0,
        image_width=48,
        image_height=48,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["class_name"] == "p23"
    assert payload["class_name_cn"] == "禁止向左转弯"
    assert payload["display_name"] == "禁止向左转弯"
    assert payload["dataset"] == "tt100k"


def test_persisted_tt100k_result_falls_back_to_raw_class_name():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolov11s")
        ),
        image_path="00000.png",
        annotated_image_url="/uploads/detections/2/0000_00000.jpg",
        class_name="unknown-code",
        class_name_cn=None,
        class_id=12,
        confidence=1.0,
        bbox=[0.0, 0.0, 48.0, 48.0],
        inference_time=2.0,
        image_width=48,
        image_height=48,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["class_name"] == "unknown-code"
    assert payload["class_name_cn"] is None
    assert payload["display_name"] == "unknown-code"
