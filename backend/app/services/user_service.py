from app.core.security import create_access_token, hash_password, verify_password
from app.entity.db_models import User
from fastapi import HTTPException
from sqlalchemy.orm import Session


class UserService:
    """用户服务"""

    @staticmethod
    def register(db: Session, username: str, email: str, password: str) -> User:
        """
        用户注册

        Args:
            db: 数据库会话
            username: 用户名
            email: 邮箱
            password: 明文密码

        Returns:
            新创建的用户对象

        Raises:
            HTTPException: 用户名或邮箱已存在
        """
        # 检查用户名是否已存在
        existing_user = db.query(User).filter(User.username == username).first()
        if existing_user:
            raise HTTPException(status_code=400, detail="用户名已存在")

        # 检查邮箱是否已存在
        existing_email = db.query(User).filter(User.email == email).first()
        if existing_email:
            raise HTTPException(status_code=400, detail="邮箱已被注册")

        # 创建新用户
        new_user = User(
            username=username,
            email=email,
            hashed_password=hash_password(password),
        )
        db.add(new_user)
        db.commit()
        db.refresh(new_user)

        return new_user

    @staticmethod
    def login(db: Session, username: str, password: str) -> User:
        """
        用户登录

        Args:
            db: 数据库会话
            username: 用户名
            password: 明文密码

        Returns:
            登录成功的用户对象

        Raises:
            HTTPException: 用户名或密码错误
        """
        user = db.query(User).filter(User.username == username).first()
        if not user:
            raise HTTPException(status_code=401, detail="用户名或密码错误")

        if not verify_password(password, user.hashed_password):
            raise HTTPException(status_code=401, detail="用户名或密码错误")

        return user

    @staticmethod
    def create_access_token_for_user(user: User) -> str:
        """为用户生成 JWT Token"""
        return create_access_token(data={"sub": str(user.id)})

    @staticmethod
    def get_user_roles(db: Session, user: User) -> list[str]:
        """获取用户的角色标识列表"""
        return [ur.role.name for ur in user.user_roles]

    @staticmethod
    def get_user_by_id(db: Session, user_id: int) -> User:
        """根据 ID 获取用户"""
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            raise HTTPException(status_code=404, detail="用户不存在")
        return user

    @staticmethod
    def get_user_by_email(db: Session, email: str) -> User:
        """根据邮箱获取用户"""
        user = db.query(User).filter(User.email == email).first()
        if not user:
            raise HTTPException(status_code=404, detail="该邮箱未注册")
        return user

    @staticmethod
    def reset_password(db: Session, email: str, new_password: str) -> User:
        """重置密码（通过邮箱）"""
        user = UserService.get_user_by_email(db, email)
        user.hashed_password = hash_password(new_password)
        db.commit()
        db.refresh(user)
        return user

    @staticmethod
    def change_password(db: Session, user: User, old_password: str, new_password: str) -> User:
        """修改密码"""
        if not verify_password(old_password, user.hashed_password):
            raise HTTPException(status_code=400, detail="旧密码不正确")
        user.hashed_password = hash_password(new_password)
        db.commit()
        db.refresh(user)
        return user

    @staticmethod
    def update_email(db: Session, user: User, new_email: str) -> User:
        """更新邮箱"""
        existing_email = db.query(User).filter(User.email == new_email).first()
        if existing_email and existing_email.id != user.id:
            raise HTTPException(status_code=400, detail="该邮箱已被注册")
        user.email = new_email
        db.commit()
        db.refresh(user)
        return user

    @staticmethod
    def update_avatar(db: Session, user: User, avatar_url: str) -> User:
        """更新头像"""
        user.avatar = avatar_url
        db.commit()
        db.refresh(user)
        return user


# 全局单例
user_service = UserService()
