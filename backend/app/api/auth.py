"""
认证相关 API 路由
- POST /api/auth/register         用户注册
- POST /api/auth/login            用户登录
- GET  /api/auth/me               获取当前用户信息
- POST /api/auth/forgot-password  忘记密码（通过邮箱重置）
- POST /api/auth/change-password  修改密码
- POST /api/auth/update-email     更新邮箱
- POST /api/auth/upload-avatar    上传头像
"""

from typing import Optional

import os
import uuid

from app.core.security import decode_access_token, hash_password
from app.database.session import get_db
from app.entity import schemas
from app.services.file_cache_service import file_cache_service
from app.services.user_service import user_service
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.security import OAuth2PasswordBearer
from fastapi.responses import JSONResponse
from jwt.exceptions import InvalidTokenError as JWTError
from sqlalchemy.orm import Session

router = APIRouter(prefix="/api/auth", tags=["认证"])

# OAuth2 密码模式，用于从请求 Header 中提取 Token
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
):
    """
    从 JWT Token 中解析当前用户
    在需要认证的路由中通过 Depends(get_current_user) 使用
    """
    credentials_exception = HTTPException(
        status_code=401,
        detail="无效的认证凭据",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_access_token(token)
        user_id_str: Optional[str] = payload.get("sub")
        if user_id_str is None:
            raise credentials_exception
        user_id = int(user_id_str)
    except (JWTError, ValueError):
        raise credentials_exception

    user = user_service.get_user_by_id(db, user_id)
    return user


@router.post("/register", response_model=schemas.UserResponse, status_code=201)
async def register(request: schemas.UserRegister, db: Session = Depends(get_db)):
    """
    用户注册

    - **username**: 用户名（3-50 字符）
    - **email**: 邮箱
    - **password**: 密码（至少 6 位）
    """
    user = user_service.register(
        db=db,
        username=request.username,
        email=request.email,
        password=request.password,
    )
    return user


@router.post("/login", response_model=schemas.TokenResponse)
async def login(request: schemas.UserLogin, db: Session = Depends(get_db)):
    """
    用户登录

    - 返回 JWT access_token
    - 后续请求在 Header 中携带：Authorization: Bearer <token>
    """
    user = user_service.login(
        db=db,
        username=request.username,
        password=request.password,
    )

    access_token = user_service.create_access_token_for_user(user)
    roles = user_service.get_user_roles(db, user)

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "user": {
            "id": user.id,
            "username": user.username,
            "email": user.email,
            "avatar": user.avatar,
            "roles": roles,
        },
    }


@router.get("/me", response_model=schemas.UserResponse)
async def get_current_user_info(
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取当前登录用户信息（需要 Token 认证）"""
    roles = user_service.get_user_roles(db, current_user)
    return {
        "id": current_user.id,
        "username": current_user.username,
        "email": current_user.email,
        "phone": current_user.phone,
        "avatar": current_user.avatar,
        "is_active": current_user.is_active,
        "is_superuser": current_user.is_superuser,
        "roles": roles,
        "last_login_at": current_user.last_login_at,
        "created_at": current_user.created_at,
    }


@router.post("/forgot-password")
async def forgot_password(email: str, db: Session = Depends(get_db)):
    """
    忘记密码（通过邮箱重置）
    
    - **email**: 用户注册的邮箱
    - 验证邮箱存在后返回成功消息（实际项目中会发送邮件包含重置链接）
    """
    try:
        user = user_service.get_user_by_email(db, email)
        return {"success": True, "message": "重置密码邮件已发送，请查收邮箱"}
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail="服务器内部错误")


@router.post("/change-password")
async def change_password(
    request: schemas.ChangePassword,
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    修改密码（需要 Token 认证）
    
    - **old_password**: 旧密码
    - **new_password**: 新密码（至少 6 位）
    """
    user = user_service.change_password(db, current_user, request.old_password, request.new_password)
    return {"success": True, "message": "密码修改成功"}


@router.post("/update-email")
async def update_email(
    request: schemas.UserUpdate,
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    更新邮箱（需要 Token 认证）
    
    - **new_email**: 新邮箱地址
    """
    user = user_service.update_email(db, current_user, request.email)
    return {"success": True, "message": "邮箱更新成功", "email": user.email}


@router.post("/upload-avatar")
async def upload_avatar(
    file: UploadFile = File(...),
    current_user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    上传头像（需要 Token 认证）
    
    - **file**: 头像图片文件（支持 jpg, jpeg, png, bmp 格式，大小不超过 2MB）
    - 支持重新上传图片
    """
    ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}
    MAX_FILE_SIZE = 2 * 1024 * 1024
    
    filename = file.filename.lower()
    ext = os.path.splitext(filename)[1]
    
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"不支持的文件格式，请上传图片文件（{', '.join(ALLOWED_EXTENSIONS)}）")
    
    file_bytes = await file.read()
    
    if len(file_bytes) > MAX_FILE_SIZE:
        raise HTTPException(status_code=400, detail="图片大小不能超过2MB")
    
    upload_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "uploads", "avatars")
    if not os.path.exists(upload_dir):
        os.makedirs(upload_dir)
    
    new_filename = f"{uuid.uuid4()}{ext}"
    file_path = os.path.join(upload_dir, new_filename)
    
    with open(file_path, "wb") as f:
        f.write(file_bytes)
    
    avatar_url = f"/uploads/avatars/{new_filename}"
    user = user_service.update_avatar(db, current_user, avatar_url)
    
    return {"success": True, "message": "头像上传成功", "avatar": avatar_url}
