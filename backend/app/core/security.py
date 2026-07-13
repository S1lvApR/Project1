from datetime import datetime, timedelta, timezone

import bcrypt
from app.config.settings import settings
from jose import jwt


def hash_password(password: str) -> str:
    """将明文密码加密为哈希值"""
    max_length = 72
    password_bytes = password.encode("utf-8")
    if len(password_bytes) > max_length:
        password_bytes = password_bytes[:max_length]
    salt = bcrypt.gensalt()
    return bcrypt.hashpw(password_bytes, salt).decode("utf-8")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """校验明文密码与哈希值是否匹配"""
    max_length = 72
    password_bytes = plain_password.encode("utf-8")
    if len(password_bytes) > max_length:
        password_bytes = password_bytes[:max_length]
    return bcrypt.checkpw(password_bytes, hashed_password.encode("utf-8"))


def get_midnight_expire() -> datetime:
    """计算到次日凌晨0点（北京时间）的过期时间，返回UTC时间"""
    tz_beijing = timezone(timedelta(hours=8))
    now_beijing = datetime.now(tz_beijing)
    tomorrow = now_beijing + timedelta(days=1)
    midnight_beijing = tomorrow.replace(hour=0, minute=0, second=0, microsecond=0)
    midnight_utc = midnight_beijing.astimezone(timezone.utc)
    return midnight_utc


def create_access_token(data: dict) -> str:
    """
    生成 JWT Access Token

    Args:
        data: Token 载荷数据，通常包含 {"sub": user_id}

    Returns:
        JWT Token 字符串
    """
    to_encode = data.copy()
    expire = get_midnight_expire()
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(
        to_encode,
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )
    return encoded_jwt


def decode_access_token(token: str) -> dict:
    """
    解析 JWT Token

    Args:
        token: JWT Token 字符串

    Returns:
        Token 载荷数据

    Raises:
        JWTError: Token 无效或已过期
    """
    return jwt.decode(
        token,
        settings.JWT_SECRET_KEY,
        algorithms=[settings.JWT_ALGORITHM],
    )
