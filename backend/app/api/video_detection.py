"""
视频检测 API 路由
- POST /api/video-detection/analyze   上传视频并开始检测（异步，返回task_id）
- GET /api/video-detection/{task_id}/progress   查询检测进度
"""

import json
import os
import uuid
from datetime import datetime

from app.api.auth import get_current_user
from app.database.session import get_db
from app.services.file_cache_service import file_cache_service
from app.services.video_detection_service import video_detection_service
from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, UploadFile
from app.core.logger import get_logger
from sqlalchemy.orm import Session

logger = get_logger(__name__)

router = APIRouter(prefix="/api/video-detection", tags=["视频检测"])


@router.post("/analyze")
async def analyze_video(
    video: UploadFile = File(...),
    frame_interval: int = 10,
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
    background_tasks: BackgroundTasks = None,
):
    """
    上传视频并开始检测（异步）
    
    - **video**: 上传的视频文件（支持 mp4, avi, mov 等格式）
    - **frame_interval**: 帧提取间隔，默认每隔10帧提取一帧
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "message": "视频检测任务已创建",
        "task_id": "uuid-string",
        "filename": "video.mp4"
    }
    """
    ALLOWED_EXTENSIONS = {".mp4", ".avi", ".mov", ".mkv", ".flv", ".wmv"}
    MAX_FILE_SIZE = 100 * 1024 * 1024

    filename = video.filename.lower()
    ext = os.path.splitext(filename)[1]

    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"不支持的文件格式，请上传视频文件（{', '.join(ALLOWED_EXTENSIONS)}）")

    video_bytes = await video.read()

    if len(video_bytes) > MAX_FILE_SIZE:
        raise HTTPException(status_code=400, detail="视频大小不能超过100MB")

    file_cache_service.store_file(
        db=db,
        file_data=video_bytes,
        file_name=filename,
        file_extension=ext,
        file_size=len(video_bytes),
        username=current_user.username,
    )

    task_id = str(uuid.uuid4())

    video_detection_service.create_task(
        task_id=task_id,
        user_id=current_user.id,
        filename=video.filename,
        frame_interval=frame_interval,
    )

    background_tasks.add_task(
        video_detection_service.process_video,
        task_id=task_id,
        video_bytes=video_bytes,
        frame_interval=frame_interval,
    )

    logger.info(f"[前端请求] 视频检测任务已创建 - task_id: {task_id}, 文件名: {video.filename}, 大小: {len(video_bytes)} bytes, 用户: {current_user.username}")

    return {
        "success": True,
        "message": "视频检测任务已创建",
        "task_id": task_id,
        "filename": video.filename,
    }


@router.get("/{task_id}/progress")
async def get_video_detection_progress(
    task_id: str,
    current_user=Depends(get_current_user),
):
    """
    查询视频检测进度
    
    - **task_id**: 任务ID
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "data": {
            "task_id": "uuid-string",
            "status": "processing",
            "progress": 50,
            "total_frames": 3000,
            "processed_frames": 150,
            "results": {...}
        }
    }
    """
    task = video_detection_service.get_task(task_id)

    if not task:
        raise HTTPException(status_code=404, detail="任务不存在")

    if task["user_id"] != current_user.id:
        raise HTTPException(status_code=403, detail="无权访问此任务")

    response_data = {
        "success": True,
        "data": {
            "task_id": task["task_id"],
            "filename": task["filename"],
            "status": task["status"],
            "progress": task["progress"],
            "total_frames": task["total_frames"],
            "processed_frames": task["processed_frames"],
            "results": task["results"],
            "error": task["error"],
            "created_at": task["created_at"].isoformat() if task["created_at"] else None,
            "started_at": task["started_at"].isoformat() if task["started_at"] else None,
            "completed_at": task["completed_at"].isoformat() if task["completed_at"] else None,
        },
    }

    return response_data
