"""
车牌识别 API 路由
- POST /api/license-plate/recognize   单张图片识别
- POST /api/license-plate/batch        批量图片识别
"""

import json
import os
from datetime import datetime

from app.api.auth import get_current_user
from app.database.session import get_db
from app.services.file_cache_service import file_cache_service
from app.services.license_plate_service import license_plate_service
from app.core.logger import get_logger
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from sqlalchemy.orm import Session

logger = get_logger(__name__)

router = APIRouter(prefix="/api/license-plate", tags=["车牌识别"])


@router.post("/recognize")
async def recognize_plate(
    image: UploadFile = File(...),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    单张图片车牌识别
    
    - **image**: 上传的图片文件（支持 jpg, jpeg, png, bmp 格式）
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "message": "识别成功",
        "data": {
            "plates": [
                {
                    "plate_number": "京A12345",
                    "plate_color": "蓝色",
                    "confidence": 95
                }
            ],
            "plate_count": 1
        }
    }
    """
    ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}
    MAX_FILE_SIZE = 2 * 1024 * 1024
    
    filename = image.filename.lower()
    ext = os.path.splitext(filename)[1]
    
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"不支持的文件格式，请上传图片文件（{', '.join(ALLOWED_EXTENSIONS)}）")
    
    image_bytes = await image.read()
    
    if len(image_bytes) > MAX_FILE_SIZE:
        raise HTTPException(status_code=400, detail="图片大小不能超过2MB")
    
    file_cache_service.store_file(
        db=db,
        file_data=image_bytes,
        file_name=filename,
        file_extension=ext,
        file_size=len(image_bytes),
        username=current_user.username,
    )
    
    logger.info(f"[前端请求] 单张图片车牌识别 - 文件名: {image.filename}, 大小: {len(image_bytes)} bytes, 用户: {current_user.username}")
    
    temp_path = license_plate_service.save_image_to_temp(image_bytes, image.filename)
    
    result = license_plate_service.recognize_from_temp(temp_path)
    
    response_data = {
        "success": result["success"],
        "message": "识别成功" if result["success"] else result["error"],
        "data": {
            "plates": result["plates"],
            "plate_count": len(result["plates"])
        }
    }
    
    logger.info(f"[后端响应] 单张图片车牌识别 - {json.dumps(response_data, ensure_ascii=False)}")
    
    return response_data


@router.post("/batch")
async def batch_recognize_plate(
    images: list[UploadFile] = File(...),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    批量图片车牌识别
    
    - **images**: 上传的图片文件列表（支持 jpg, jpeg, png, bmp 格式）
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "message": "批量识别完成",
        "data": {
            "results": [
                {
                    "success": true,
                    "plates": [...]
                }
            ],
            "total_plates": 5
        }
    }
    """
    ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}
    MAX_FILE_SIZE = 2 * 1024 * 1024
    
    filenames = [file.filename for file in images]
    logger.info(f"[前端请求] 批量图片车牌识别 - 文件数: {len(images)}, 文件名: {filenames}, 用户: {current_user.username}")
    
    image_list = []
    
    for file in images:
        file_bytes = await file.read()
        filename = file.filename.lower()
        ext = os.path.splitext(filename)[1]
        
        if len(file_bytes) > MAX_FILE_SIZE:
            raise HTTPException(status_code=400, detail=f"文件 {file.filename} 大小不能超过2MB")
        
        if ext in ALLOWED_EXTENSIONS:
            file_cache_service.store_file(
                db=db,
                file_data=file_bytes,
                file_name=filename,
                file_extension=ext,
                file_size=len(file_bytes),
                username=current_user.username,
            )
            
            image_list.append(file_bytes)
    
    if len(image_list) == 0:
        return {
            "success": False,
            "message": "未找到有效的图片文件",
            "data": None
        }
    
    result = license_plate_service.batch_recognize(image_list)
    
    response_data = {
        "success": True,
        "message": f"批量识别完成，共 {len(image_list)} 张图片",
        "data": {
            "results": result["results"],
            "total_plates": result["total_plates"]
        }
    }
    
    logger.info(f"[后端响应] 批量图片车牌识别 - {json.dumps(response_data, ensure_ascii=False)}")
    
    return response_data