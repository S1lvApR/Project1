"""Authenticated TT100K traffic-sign detection endpoints."""

from datetime import datetime
from io import BytesIO
from pathlib import Path
from zipfile import BadZipFile, ZipFile

from PIL import Image, UnidentifiedImageError
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from sqlalchemy.orm import Session

from app.api.auth import get_current_user
from app.config.settings import settings
from app.database.session import get_db
from app.services.detection_task_service import (
    DetectionInput,
    DetectionTaskService,
    TaskNotFoundError,
    detection_task_service,
)
from app.services.file_cache_service import file_cache_service
from app.services.recognition_router import VALID_MODES
from app.services.tt100k_labels import tt100k_label_zh
from app.services.yolo_detector import ModelUnavailableError

router = APIRouter(prefix="/api/sign-analyzer", tags=["交通标志识别"])
ALLOWED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}


def _safe_filename(filename: str | None) -> str:
    return Path(filename or "upload").name


def _validate_image_bytes(content: bytes, filename: str) -> None:
    try:
        image = Image.open(BytesIO(content))
        image.verify()
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise HTTPException(
            status_code=400,
            detail=f"文件 {filename} 不是有效图片: {exc}",
        ) from exc


def _store_upload(
    db: Session,
    content: bytes,
    filename: str,
    username: str,
) -> None:
    extension = Path(filename).suffix.lower()
    file_cache_service.store_file(
        db=db,
        file_data=content,
        file_name=filename,
        file_extension=extension,
        file_size=len(content),
        username=username,
    )


def _extract_zip_images(content: bytes, archive_name: str) -> list[DetectionInput]:
    images: list[DetectionInput] = []
    total_bytes = 0
    try:
        archive = ZipFile(BytesIO(content))
    except BadZipFile as exc:
        raise HTTPException(
            status_code=400, detail=f"ZIP 文件 {archive_name} 损坏"
        ) from exc

    with archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            extension = Path(info.filename).suffix.lower()
            if extension not in ALLOWED_IMAGE_EXTENSIONS:
                continue
            if len(images) >= settings.YOLO_MAX_BATCH_IMAGES:
                raise HTTPException(status_code=400, detail="批量图片数量超过限制")
            if info.file_size > settings.YOLO_MAX_IMAGE_BYTES:
                raise HTTPException(
                    status_code=400,
                    detail=f"ZIP 内文件 {info.filename} 大小超过限制",
                )
            total_bytes += info.file_size
            if total_bytes > settings.YOLO_MAX_IMAGE_BYTES * settings.YOLO_MAX_BATCH_IMAGES:
                raise HTTPException(status_code=400, detail="ZIP 解压后的总大小超过限制")
            images.append(
                DetectionInput(
                    filename=_safe_filename(info.filename),
                    content=archive.read(info),
                )
            )
    return images


async def _read_upload(
    db: Session,
    upload: UploadFile,
    username: str,
    allow_zip: bool,
    validate_image: bool = False,
) -> list[DetectionInput]:
    filename = _safe_filename(upload.filename)
    extension = Path(filename).suffix.lower()
    content = await upload.read()
    if len(content) > settings.YOLO_MAX_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail=f"文件 {filename} 大小超过限制")

    if extension == ".zip":
        if not allow_zip:
            raise HTTPException(status_code=400, detail="单图接口不支持 ZIP 文件")
        _store_upload(db, content, filename, username)
        return _extract_zip_images(content, filename)

    if extension not in ALLOWED_IMAGE_EXTENSIONS:
        allowed = ", ".join(sorted(ALLOWED_IMAGE_EXTENSIONS))
        raise HTTPException(status_code=400, detail=f"不支持的图片格式，可用格式: {allowed}")
    if validate_image:
        _validate_image_bytes(content, filename)
    _store_upload(db, content, filename, username)
    return [DetectionInput(filename=filename, content=content)]


def _model_payload(outcome) -> dict:
    model = outcome.model_version
    return {
        "id": model.id,
        "version": model.version,
        "name": model.model_name,
        "type": model.model_type,
        "path": model.model_path,
        "device": outcome.device,
        "dataset": "gtsrb" if model.model_type == "yolo11n-cls" else "tt100k",
    }


def _recognition_metadata(model_type: str | None) -> dict:
    is_classification = model_type == "yolo11n-cls"
    return {
        "recognition_mode": "classify" if is_classification else "detect",
        "result_type": "classification" if is_classification else "detection",
        "dataset": "gtsrb" if is_classification else "tt100k",
        "model_family": (
            "gtsrb-classifier" if is_classification else "tt100k-detector"
        ),
    }


def _task_payload(task) -> dict:
    model = task.model_version
    return {
        "id": task.id,
        "user_id": task.user_id,
        "scene_id": task.scene_id,
        "scene_name": task.scene.name if task.scene else None,
        "model_version_id": task.model_version_id,
        "model_name": model.model_name if model else None,
        "model_device": None,
        "task_type": task.task_type,
        "status": task.status,
        "total_images": task.total_images,
        "total_objects": task.total_objects,
        "total_inference_time": task.total_inference_time,
        "conf_threshold": task.conf_threshold,
        "iou_threshold": task.iou_threshold,
        "error_message": task.error_message,
        "created_at": task.created_at,
        "completed_at": task.completed_at,
        **_recognition_metadata(model.model_type if model else None),
    }


def _result_payload(result) -> dict:
    model_version = result.task.model_version if result.task else None
    metadata = _recognition_metadata(
        model_version.model_type if model_version else None
    )
    class_name_cn = result.class_name_cn
    if not class_name_cn:
        class_name_cn = tt100k_label_zh(result.class_name)
    return {
        "id": result.id,
        "task_id": result.task_id,
        "image_path": result.image_path,
        "annotated_image_url": result.annotated_image_url,
        "class_name": result.class_name,
        "class_name_cn": class_name_cn,
        "display_name": class_name_cn or result.class_name,
        "class_id": result.class_id,
        "confidence": result.confidence,
        "bbox": result.bbox,
        "inference_time": result.inference_time,
        "image_width": result.image_width,
        "image_height": result.image_height,
        **metadata,
        "created_at": result.created_at,
    }


def _run_task(
    service: DetectionTaskService,
    db: Session,
    user_id: int,
    images: list[DetectionInput],
    task_type: str,
    confidence: float | None,
    iou: float | None,
    image_size: int | None,
    mode: str | None,
):
    resolved_confidence = settings.YOLO_CONFIDENCE if confidence is None else confidence
    resolved_iou = settings.YOLO_IOU if iou is None else iou
    resolved_image_size = settings.YOLO_IMAGE_SIZE if image_size is None else image_size
    resolved_mode = (mode or "auto").strip().lower()
    if resolved_mode not in VALID_MODES:
        allowed = ", ".join(sorted(VALID_MODES))
        raise HTTPException(status_code=400, detail=f"mode must be one of: {allowed}")
    if not 0 <= resolved_confidence <= 1:
        raise HTTPException(status_code=400, detail="confidence 必须在 0 到 1 之间")
    if not 0 <= resolved_iou <= 1:
        raise HTTPException(status_code=400, detail="iou 必须在 0 到 1 之间")
    if not 32 <= resolved_image_size <= 4096:
        raise HTTPException(status_code=400, detail="image_size 必须在 32 到 4096 之间")
    try:
        return service.run_task(
            db=db,
            user_id=user_id,
            images=images,
            task_type=task_type,
            confidence=resolved_confidence,
            iou=resolved_iou,
            image_size=resolved_image_size,
            mode=resolved_mode,
        )
    except ModelUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.post("/analyze")
async def analyze_sign(
    image: UploadFile = File(...),
    confidence: float | None = Form(None),
    iou: float | None = Form(None),
    image_size: int | None = Form(None),
    mode: str | None = Form(None),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    images = await _read_upload(
        db=db,
        upload=image,
        username=current_user.username,
        allow_zip=False,
        validate_image=True,
    )
    outcome = _run_task(
        detection_task_service,
        db,
        current_user.id,
        images,
        "single",
        confidence,
        iou,
        image_size,
        mode,
    )
    image_result = outcome.images[0]
    if not image_result["success"]:
        raise HTTPException(status_code=400, detail=image_result["error"])

    data = {
        "time": datetime.now().strftime("%Y/%m/%d %H:%M:%S"),
        "task_id": outcome.task.id,
        "model": _model_payload(outcome),
        "filename": image_result["filename"],
        "traffic_signs": image_result["traffic_signs"],
        "traffic_lights": image_result["traffic_lights"],
        "annotated_image_url": image_result["annotated_image_url"],
        "image_width": image_result["image_width"],
        "image_height": image_result["image_height"],
        "inference_time": image_result["inference_time"],
        "recognition_mode": image_result.get("recognition_mode", "detect"),
        "result_type": image_result.get("result_type", "detection"),
        "dataset": image_result.get("dataset", "tt100k"),
        "model_family": image_result.get("model_family", "tt100k-detector"),
        "results": [image_result],
    }
    return {"success": True, "message": "识别成功", "data": data}


@router.post("/batch")
async def batch_analyze_sign(
    files: list[UploadFile] = File(...),
    confidence: float | None = Form(None),
    iou: float | None = Form(None),
    image_size: int | None = Form(None),
    mode: str | None = Form(None),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    images: list[DetectionInput] = []
    for upload in files:
        images.extend(
            await _read_upload(
                db=db,
                upload=upload,
                username=current_user.username,
                allow_zip=True,
            )
        )
        if len(images) > settings.YOLO_MAX_BATCH_IMAGES:
            raise HTTPException(status_code=400, detail="批量图片数量超过限制")

    if not images:
        raise HTTPException(status_code=400, detail="未找到有效的图片文件")

    outcome = _run_task(
        detection_task_service,
        db,
        current_user.id,
        images,
        "batch",
        confidence,
        iou,
        image_size,
        mode,
    )
    if outcome.task.status == "failed":
        raise HTTPException(status_code=400, detail=outcome.task.error_message)

    total_signs = sum(len(item["traffic_signs"]) for item in outcome.images)
    return {
        "success": True,
        "message": f"批量识别完成，共 {len(outcome.images)} 张图片",
        "data": {
            "time": datetime.now().strftime("%Y/%m/%d %H:%M:%S"),
            "task_id": outcome.task.id,
            "model": _model_payload(outcome),
            "total_images": len(outcome.images),
            "total_signs": total_signs,
            "total_lights": 0,
            "recognition_modes": sorted(
                {item.get("recognition_mode", "detect") for item in outcome.images}
            ),
            "results": outcome.images,
        },
    }


@router.get("/tasks")
def list_detection_tasks(
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    tasks = detection_task_service.list_tasks(db, current_user.id)
    return {"success": True, "data": [_task_payload(task) for task in tasks]}


@router.get("/tasks/{task_id}")
def get_detection_task(
    task_id: int,
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        task = detection_task_service.get_task(db, current_user.id, task_id)
    except TaskNotFoundError as exc:
        raise HTTPException(status_code=404, detail="识别任务不存在") from exc
    return {
        "success": True,
        "data": {
            "task": _task_payload(task),
            "results": [_result_payload(result) for result in task.results],
        },
    }
