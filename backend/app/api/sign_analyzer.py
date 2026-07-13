"""
交通标志与信号灯识别 API 路由
- POST /api/sign-analyzer/analyze   单张图片识别
- POST /api/sign-analyzer/batch      批量图片识别（支持文件夹和zip）
"""

import json
import os
from datetime import datetime

from app.api.auth import get_current_user
from app.database.session import get_db
from app.services.file_cache_service import file_cache_service
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from app.services.sign_analyzer_service import sign_analyzer_service
from app.core.logger import get_logger
from sqlalchemy.orm import Session

logger = get_logger(__name__)

router = APIRouter(prefix="/api/sign-analyzer", tags=["交通标志与信号灯识别"])


@router.post("/analyze")
async def analyze_sign(
    image: UploadFile = File(...),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    单张图片交通标志与信号灯识别
    
    - **image**: 上传的图片文件（支持 jpg, jpeg, png, bmp 格式）
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "message": "识别成功",
        "data": {
            "time": "2026/07/09",
            "agent_name": "SignAnalyzer",
            "traffic_signs": [
                {
                    "type": "限速标志",
                    "value": "60",
                    "unit": "km/h",
                    "confidence": 95,
                    "location": {"left": 100, "top": 80, "width": 60, "height": 60}
                }
            ],
            "traffic_lights": [
                {
                    "type": "信号灯",
                    "status": "red",
                    "confidence": 92,
                    "location": {"left": 300, "top": 50, "width": 40, "height": 100}
                }
            ]
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
    
    logger.info(f"[前端请求] 单张图片交通标志与信号灯识别 - 文件名: {image.filename}, 大小: {len(image_bytes)} bytes, 用户: {current_user.username}")
    
    temp_path = sign_analyzer_service.save_image_to_temp(image_bytes, image.filename)
    
    result = sign_analyzer_service.analyze_from_temp(temp_path)
    
    current_time = datetime.now().strftime("%Y/%m/%d %H:%M:%S")
    
    response_data = {
        "success": result["success"],
        "message": "识别成功" if result["success"] else result["error"],
        "data": {
            "time": current_time,
            "traffic_signs": result["traffic_signs"],
            "traffic_lights": result["traffic_lights"]
        }
    }
    
    logger.info(f"[后端响应] 单张图片交通标志与信号灯识别 - {json.dumps(response_data, ensure_ascii=False)}")
    
    return response_data


@router.post("/batch")
async def batch_analyze_sign(
    files: list[UploadFile] = File(...),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    批量图片交通标志与信号灯识别（支持上传一张或多张图片、文件夹或zip）
    
    - **files**: 上传的文件列表（支持 jpg, jpeg, png, bmp 格式的图片文件或 zip 压缩文件）
    - 需要 Token 认证
    
    返回格式：
    {
        "success": true,
        "message": "批量识别完成",
        "data": {
            "time": "2026/07/09",
            "total_images": 3,
            "total_signs": 5,
            "total_lights": 2,
            "agent_name": "SignAnalyzer",
            "results": [
                {
                    "image_index": 0,
                    "success": true,
                    "traffic_signs": [...],
                    "traffic_lights": [...]
                }
            ]
        }
    }
    """
    ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}
    MAX_FILE_SIZE = 2 * 1024 * 1024
    
    filenames = [file.filename for file in files]
    logger.info(f"[前端请求] 批量图片交通标志与信号灯识别 - 文件数: {len(files)}, 文件名: {filenames}, 用户: {current_user.username}")
    
    temp_paths = []
    image_list = []
    
    for file in files:
        file_bytes = await file.read()
        filename = file.filename.lower()
        ext = os.path.splitext(filename)[1]
        
        if len(file_bytes) > MAX_FILE_SIZE:
            raise HTTPException(status_code=400, detail=f"文件 {file.filename} 大小不能超过2MB")
        
        if filename.endswith('.zip'):
            file_cache_service.store_file(
                db=db,
                file_data=file_bytes,
                file_name=filename,
                file_extension=ext,
                file_size=len(file_bytes),
                username=current_user.username,
            )
            
            zip_images, zip_filenames = sign_analyzer_service.extract_zip(file_bytes)
            image_list.extend(zip_images)
            logger.info(f"从ZIP文件 {file.filename} 中提取了 {len(zip_images)} 张图片")
            continue
        
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
            temp_path = sign_analyzer_service.save_image_to_temp(file_bytes, file.filename)
            temp_paths.append(temp_path)
    
    if len(image_list) == 0:
        return {
            "success": False,
            "message": "未找到有效的图片文件",
            "data": None
        }
    
    result = sign_analyzer_service.batch_analyze(image_list)
    
    for temp_path in temp_paths:
        sign_analyzer_service.delete_temp_image(temp_path)
    
    current_time = datetime.now().strftime("%Y/%m/%d %H:%M:%S")
    
    response_data = {
        "success": True,
        "message": f"批量识别完成，共 {len(image_list)} 张图片",
        "data": {
            "time": current_time,
            "total_images": result["total_images"],
            "total_signs": result["total_signs"],
            "total_lights": result["total_lights"],
            "results": result["results"]
        }
    }
    
    logger.info(f"[后端响应] 批量图片交通标志与信号灯识别 - {json.dumps(response_data, ensure_ascii=False)}")
    
    return response_data