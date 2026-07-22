from types import SimpleNamespace

from app.api import detection
from app.config.settings import Settings
from fastapi.websockets import WebSocketDisconnect
import pytest
from pydantic import ValidationError
from app.services.detection_task_service import TaskNotFoundError
from app.services.yolo_detector import ModelUnavailableError


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


class FakeVideoService:
    def __init__(self):
        self.status = {
            "task_id": 91,
            "status": "processing",
            "progress": 40,
            "key_frames": [],
        }
        self.status_calls = []

    def get_status(self, db, user_id, task_id):
        del db
        self.status_calls.append((user_id, task_id))
        if task_id != 91:
            raise TaskNotFoundError("missing")
        return self.status


def test_video_settings_use_full_timeline_defaults():
    video_settings = Settings(_env_file=None)

    assert video_settings.VIDEO_FRAME_SAMPLE_RATE == 1
    assert video_settings.VIDEO_MAX_FRAMES == 0
    assert video_settings.VIDEO_PREVIEW_INTERVAL_FRAMES == 10
    assert video_settings.VIDEO_KEY_FRAME_INTERVAL_SECONDS == 1.0
    assert video_settings.VIDEO_MAX_KEY_FRAMES == 100
    assert video_settings.VIDEO_BOX_PERSISTENCE_FRAMES == 3
    assert video_settings.VIDEO_ANNOTATION_FONT_PATH == ""


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("VIDEO_FRAME_SAMPLE_RATE", 0),
        ("VIDEO_MAX_FRAMES", -1),
        ("VIDEO_PREVIEW_INTERVAL_FRAMES", 0),
        ("VIDEO_KEY_FRAME_INTERVAL_SECONDS", -0.1),
        ("VIDEO_MAX_KEY_FRAMES", 0),
        ("VIDEO_MAX_KEY_FRAMES", 1001),
        ("VIDEO_BOX_PERSISTENCE_FRAMES", -1),
        ("VIDEO_BOX_PERSISTENCE_FRAMES", 31),
    ],
)
def test_video_settings_reject_out_of_range_values(field, value):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, **{field: value})


@pytest.mark.parametrize("max_frames", [0, 100000])
def test_video_options_accept_supported_max_frame_bounds(max_frames):
    resolved = detection._resolve_options(None, None, None, None, max_frames)

    assert resolved[4] == max_frames


@pytest.mark.parametrize("max_frames", [-1, 100001])
def test_video_options_reject_max_frames_outside_bounds(max_frames):
    with pytest.raises(detection.HTTPException) as raised:
        detection._resolve_options(None, None, None, None, max_frames)

    assert raised.value.status_code == 400


def test_video_upload_requires_authentication(client):
    response = client.post(
        "/api/detection/video",
        files={"video": ("road.mp4", b"video", "video/mp4")},
    )

    assert response.status_code == 401


def test_video_upload_validates_format_and_size(client, monkeypatch):
    headers = authenticate(client, "video_validation_user")
    unsupported = client.post(
        "/api/detection/video",
        headers=headers,
        files={"video": ("road.txt", b"video", "text/plain")},
    )
    monkeypatch.setattr(detection.settings, "VIDEO_MAX_BYTES", 4)
    oversized = client.post(
        "/api/detection/video",
        headers=headers,
        files={"video": ("road.mp4", b"12345", "video/mp4")},
    )

    assert unsupported.status_code == 400
    assert oversized.status_code == 413


def test_video_upload_submits_agent_tool_with_resolved_options(
    client, monkeypatch
):
    headers = authenticate(client, "video_submit_user")
    calls = []

    def fake_tool(**kwargs):
        calls.append(kwargs)
        return SimpleNamespace(task_id=91, status="pending")

    monkeypatch.setattr(detection, "detect_video_file", fake_tool)
    fake_service = FakeVideoService()
    monkeypatch.setattr(detection, "video_detection_service", fake_service)

    response = client.post(
        "/api/detection/video",
        headers=headers,
        data={
            "confidence": "0.3",
            "iou": "0.5",
            "image_size": "640",
            "sample_rate": "2",
            "max_frames": "20",
        },
        files={"video": ("../road.mp4", b"video", "video/mp4")},
    )

    assert response.status_code == 202
    payload = response.json()["data"]
    assert payload == {"task_id": 91, "status": "pending", "progress": 0}
    assert calls[0]["filename"] == "road.mp4"
    assert calls[0]["content"] == b"video"
    assert calls[0]["confidence"] == 0.3
    assert calls[0]["sample_rate"] == 2
    assert calls[0]["max_frames"] == 20


def test_video_status_is_authenticated_and_user_scoped(client, monkeypatch):
    headers = authenticate(client, "video_status_user")
    fake_service = FakeVideoService()
    monkeypatch.setattr(detection, "video_detection_service", fake_service)

    response = client.get(
        "/api/detection/video/status/91",
        headers=headers,
    )
    missing = client.get(
        "/api/detection/video/status/999",
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["data"]["progress"] == 40
    assert fake_service.status_calls[0][1] == 91
    assert missing.status_code == 404


def login_token(client, username):
    headers = authenticate(client, username)
    return headers["Authorization"].split(" ", 1)[1]


class FakeCameraProcessor:
    def configure(self, message):
        assert message["type"] == "config"
        return {
            "type": "config_ok",
            "mode": "gpu",
            "device": "0",
            "image_size": 640,
            "confidence": 0.25,
            "iou": 0.45,
        }

    def process_frame(self, encoded_frame):
        assert encoded_frame == "frame-data"
        return {
            "type": "result",
            "annotated_frame": "annotated",
            "detections": [],
            "object_count": 0,
            "inference_time": 4.0,
            "fps": 20.0,
            "frame_count": 1,
            "device": "0",
        }


def test_camera_websocket_requires_config_then_streams_one_response_per_frame(
    client, monkeypatch
):
    token = login_token(client, "camera_ws_user")
    monkeypatch.setattr(
        detection,
        "create_camera_processor",
        lambda: FakeCameraProcessor(),
    )
    thread_calls = []

    async def fake_run_in_threadpool(function, *args):
        thread_calls.append(function.__name__)
        return function(*args)

    monkeypatch.setattr(detection, "run_in_threadpool", fake_run_in_threadpool)

    with client.websocket_connect(
        f"/api/detection/camera?token={token}"
    ) as websocket:
        websocket.send_json({"type": "frame", "data": "frame-data"})
        assert websocket.receive_json()["type"] == "error"
        websocket.send_json({"type": "config", "mode": "gpu"})
        assert websocket.receive_json()["type"] == "config_ok"
        websocket.send_json({"type": "frame", "data": "frame-data"})
        assert websocket.receive_json() == {
            "type": "result",
            "annotated_frame": "annotated",
            "detections": [],
            "object_count": 0,
            "inference_time": 4.0,
            "fps": 20.0,
            "frame_count": 1,
            "device": "0",
        }
        websocket.send_json({"type": "close"})

    assert thread_calls == ["configure", "process_frame"]


def test_camera_websocket_rejects_missing_token(client):
    with pytest.raises(WebSocketDisconnect) as raised:
        with client.websocket_connect("/api/detection/camera"):
            pass

    assert raised.value.code == 4401


def test_camera_websocket_recovers_from_malformed_json(client):
    token = login_token(client, "camera_json_user")

    with client.websocket_connect(
        f"/api/detection/camera?token={token}"
    ) as websocket:
        websocket.send_text("{")
        assert websocket.receive_json()["type"] == "error"
        websocket.send_json({"type": "close"})


def test_video_submission_hides_model_filesystem_details(client, monkeypatch):
    headers = authenticate(client, "video_secure_error_user")

    def fail_tool(**_kwargs):
        raise ModelUnavailableError("missing D:/secret/models/best.pt")

    monkeypatch.setattr(detection, "detect_video_file", fail_tool)
    response = client.post(
        "/api/detection/video",
        headers=headers,
        files={"video": ("road.mp4", b"video", "video/mp4")},
    )

    assert response.status_code == 503
    assert "D:/secret" not in str(response.json())
