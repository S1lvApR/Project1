from datetime import datetime

from app.entity.db_models import FileCache
from sqlalchemy.orm import Session


class FileCacheService:
    """文件缓存服务"""

    @staticmethod
    def store_file(
        db: Session,
        file_data: bytes,
        file_name: str,
        file_extension: str,
        file_size: int,
        username: str,
    ) -> FileCache:
        """
        存储文件到数据库缓存

        Args:
            db: 数据库会话
            file_data: 文件二进制数据
            file_name: 原始文件名
            file_extension: 文件扩展名
            file_size: 文件大小（字节）
            username: 上传用户名

        Returns:
            FileCache 对象
        """
        cache_entry = FileCache(
            file_data=file_data,
            file_name=file_name,
            file_extension=file_extension,
            file_size=file_size,
            username=username,
            uploaded_at=datetime.now(),
        )
        db.add(cache_entry)
        db.commit()
        db.refresh(cache_entry)
        return cache_entry

    @staticmethod
    def get_file_by_id(db: Session, file_id: int) -> FileCache:
        """
        根据 ID 获取缓存文件

        Args:
            db: 数据库会话
            file_id: 文件缓存 ID

        Returns:
            FileCache 对象，如果不存在返回 None
        """
        return db.query(FileCache).filter(FileCache.id == file_id).first()

    @staticmethod
    def get_files_by_username(db: Session, username: str) -> list[FileCache]:
        """
        根据用户名获取所有缓存文件

        Args:
            db: 数据库会话
            username: 用户名

        Returns:
            FileCache 对象列表
        """
        return db.query(FileCache).filter(FileCache.username == username).all()

    @staticmethod
    def delete_file(db: Session, file_id: int) -> bool:
        """
        删除指定缓存文件

        Args:
            db: 数据库会话
            file_id: 文件缓存 ID

        Returns:
            是否删除成功
        """
        cache_entry = db.query(FileCache).filter(FileCache.id == file_id).first()
        if cache_entry:
            db.delete(cache_entry)
            db.commit()
            return True
        return False

    @staticmethod
    def clear_all(db: Session) -> int:
        """
        清空所有缓存文件

        Args:
            db: 数据库会话

        Returns:
            删除的记录数
        """
        count = db.query(FileCache).count()
        db.query(FileCache).delete()
        db.commit()
        return count

    @staticmethod
    def clear_expired(db: Session, before_time: datetime) -> int:
        """
        删除指定时间之前的缓存文件

        Args:
            db: 数据库会话
            before_time: 删除此时间之前的文件

        Returns:
            删除的记录数
        """
        count = db.query(FileCache).filter(FileCache.uploaded_at < before_time).count()
        db.query(FileCache).filter(FileCache.uploaded_at < before_time).delete()
        db.commit()
        return count


file_cache_service = FileCacheService()