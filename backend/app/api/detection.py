"""Authenticated video and realtime camera detection endpoints."""

import json
from pathlib import Path

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from jwt.exceptions import InvalidTokenError as JWTError
from starlette.concurrency import run_in_threadpool
from sqlalchemy.orm import Session

from app.agent.detection_agent import detect_video_file
from app.api.auth import get_current_user
from app.config.settings import settings
from app.core.logger import get_logger
from app.core.security import decode_access_token
from app.database.session import get_db
from app.services.camera_detection_service import (
    CameraDetectionProcessor,
    CameraProtocolError,
)
from app.services.detection_task_service import TaskNotFoundError
from app.services.video_detection_service import (
    VideoProcessingError,
    VideoQueueFullError,
    video_detection_service,
)
from app.services.yolo_detector import ModelUnavailableError
from app.services.user_service import user_service

router = APIRouter(prefix="/api/detection", tags=["视频与摄像头检测"])
logger = get_logger(__name__)

ALLOWED_VIDEO_EXTENSIONS = {
    ".mp4",
    ".avi",
    ".mov",
    ".mkv",
    ".wmv",
    ".flv",
}


def _resolve_options(
    confidence: float | None,
    iou: float | None,
    image_size: int | None,
    sample_rate: int | None,
    max_frames: int | None,
) -> tuple[float, float, int, int, int]:
    resolved = (
        settings.YOLO_CONFIDENCE if confidence is None else confidence,
        settings.YOLO_IOU if iou is None else iou,
        settings.YOLO_IMAGE_SIZE if image_size is None else image_size,
        settings.VIDEO_FRAME_SAMPLE_RATE if sample_rate is None else sample_rate,
        settings.VIDEO_MAX_FRAMES if max_frames is None else max_frames,
    )
    resolved_confidence, resolved_iou, resolved_size, resolved_rate, resolved_max = (
        resolved
    )
    if not 0 <= resolved_confidence <= 1:
        raise HTTPException(status_code=400, detail="confidence 必须在 0 到 1 之间")
    if not 0 <= resolved_iou <= 1:
        raise HTTPException(status_code=400, detail="iou 必须在 0 到 1 之间")
    if not 32 <= resolved_size <= 4096:
        raise HTTPException(status_code=400, detail="image_size 必须在 32 到 4096 之间")
    if not 1 <= resolved_rate <= 1000:
        raise HTTPException(status_code=400, detail="sample_rate 必须在 1 到 1000 之间")
    if not 0 <= resolved_max <= 100000:
        raise HTTPException(
            status_code=400,
            detail="max_frames 必须在 0 到 100000 之间",
        )
    return resolved


@router.post("/video", status_code=202)
async def submit_video_detection(
    video: UploadFile = File(...),
    confidence: float | None = Form(None),
    iou: float | None = Form(None),
    image_size: int | None = Form(None),
    sample_rate: int | None = Form(None),
    max_frames: int | None = Form(None),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    filename = Path(video.filename or "video").name
    extension = Path(filename).suffix.lower()
    if extension not in ALLOWED_VIDEO_EXTENSIONS:
        allowed = ", ".join(sorted(ALLOWED_VIDEO_EXTENSIONS))
        raise HTTPException(
            status_code=400,
            detail=f"不支持的视频格式，可用格式: {allowed}",
        )
    content = await video.read(settings.VIDEO_MAX_BYTES + 1)
    await video.close()
    if len(content) > settings.VIDEO_MAX_BYTES:
        raise HTTPException(status_code=413, detail="视频大小超过 50 MB 限制")
    if not content:
        raise HTTPException(status_code=400, detail="视频文件为空")

    options = _resolve_options(
        confidence,
        iou,
        image_size,
        sample_rate,
        max_frames,
    )
    try:
        submission = detect_video_file(
            service=video_detection_service,
            db=db,
            user_id=current_user.id,
            filename=filename,
            content=content,
            confidence=options[0],
            iou=options[1],
            image_size=options[2],
            sample_rate=options[3],
            max_frames=options[4],
        )
    except VideoQueueFullError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except ModelUnavailableError as exc:
        logger.exception("Video detector is unavailable")
        raise HTTPException(
            status_code=503,
            detail="检测模型暂不可用，请检查服务配置",
        ) from exc
    except VideoProcessingError as exc:
        logger.exception("Unable to submit video detection task")
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {
        "success": True,
        "message": "视频检测任务已创建",
        "data": {
            "task_id": submission.task_id,
            "status": submission.status,
            "progress": 0,
        },
    }


@router.get("/video/status/{task_id}")
def get_video_detection_status(
    task_id: int,
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        status = video_detection_service.get_status(db, current_user.id, task_id)
    except TaskNotFoundError as exc:
        raise HTTPException(status_code=404, detail="视频检测任务不存在") from exc
    return {"success": True, "data": status}


def create_camera_processor() -> CameraDetectionProcessor:
    return CameraDetectionProcessor(detector=video_detection_service.detector)


def _authenticate_websocket_user(token: str | None, db: Session):
    if not token:
        raise ValueError("Missing authentication token")
    try:
        payload = decode_access_token(token)
        user_id = int(payload.get("sub"))
    except (JWTError, TypeError, ValueError) as exc:
        raise ValueError("Invalid authentication token") from exc
    return user_service.get_user_by_id(db, user_id)


@router.websocket("/camera")
async def camera_detection_websocket(
    websocket: WebSocket,
    token: str | None = None,
    db: Session = Depends(get_db),
):
    try:
        _authenticate_websocket_user(token, db)
    except (HTTPException, ValueError):
        await websocket.close(code=4401, reason="Unauthorized")
        return

    await websocket.accept()
    processor = create_camera_processor()
    configured = False
    try:
        while True:
            try:
                message = await websocket.receive_json()
            except json.JSONDecodeError:
                await websocket.send_json(
                    {"type": "error", "message": "Camera message is not valid JSON"}
                )
                continue
            message_type = message.get("type") if isinstance(message, dict) else None
            if message_type == "close":
                await websocket.close(code=1000)
                return
            try:
                if message_type == "config":
                    response = await run_in_threadpool(processor.configure, message)
                    configured = True
                elif message_type == "frame":
                    if not configured:
                        raise CameraProtocolError(
                            "请先发送 config 消息初始化摄像头检测"
                        )
                    response = await run_in_threadpool(
                        processor.process_frame,
                        message.get("data", ""),
                    )
                else:
                    raise CameraProtocolError("Unsupported camera message type")
            except CameraProtocolError as exc:
                response = {"type": "error", "message": str(exc)}
            except ModelUnavailableError:
                logger.exception("Camera detector is unavailable")
                response = {
                    "type": "error",
                    "message": "检测模型暂不可用，请检查服务配置",
                }
            except Exception:
                logger.exception("Unexpected camera frame processing failure")
                response = {
                    "type": "error",
                    "message": "摄像头帧处理失败，请查看服务日志",
                }
            await websocket.send_json(response)
    except WebSocketDisconnect:
        return
