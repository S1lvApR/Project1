"""
Redis 客户端 — 支持内存缓存降级

职责：
  - 封装 Redis 操作
  - 当 Redis 不可用时，自动降级到内存缓存
  - 提供兼容的 API 接口

设计：
  - 生产环境：使用真实 Redis
  - 开发环境：使用内存缓存（字典）
  - 支持 TTL 过期机制（简化实现）
"""

import time
from typing import Optional

from app.config.settings import settings
from app.core.logger import get_logger

logger = get_logger(__name__)


class MemoryCache:
    """内存缓存实现（用于开发环境）"""

    def __init__(self):
        self._data = {}
        self._ttl_data = {}

    def set(self, key: str, value: str, expire: Optional[int] = None):
        """设置值，可选过期时间（秒）"""
        self._data[key] = value
        if expire is not None:
            self._ttl_data[key] = time.time() + expire

    def get(self, key: str) -> Optional[str]:
        """获取值"""
        # 检查过期
        if key in self._ttl_data:
            if time.time() > self._ttl_data[key]:
                self.delete(key)
                return None
        return self._data.get(key)

    def lpush(self, key: str, value: str):
        """List 左侧推入"""
        if key not in self._data:
            self._data[key] = []
        if isinstance(self._data[key], list):
            self._data[key].insert(0, value)

    def lrange(self, key: str, start: int, end: int) -> list:
        """获取 List 范围"""
        data = self._data.get(key, [])
        if not isinstance(data, list):
            return []
        return data[start:end+1]

    def delete(self, key: str):
        """删除键"""
        self._data.pop(key, None)
        self._ttl_data.pop(key, None)


class RedisClient:
    """Redis 客户端封装"""

    def __init__(self):
        self._client = None
        self._memory_cache = MemoryCache()
        self._use_memory = not settings.redis_enabled

        if not self._use_memory:
            try:
                self._connect_redis()
            except Exception as e:
                logger.warning("Redis 连接失败，降级到内存缓存: %s", str(e))
                self._use_memory = True

    def _connect_redis(self):
        """连接 Redis"""
        try:
            import redis
            self._client = redis.Redis(
                host=settings.REDIS_HOST,
                port=settings.REDIS_PORT,
                decode_responses=True,
            )
            self._client.ping()
            logger.info("Redis 连接成功")
        except Exception as e:
            raise ConnectionError(f"Redis 连接失败: {e}")

    def set(self, key: str, value: str, expire: Optional[int] = None):
        """设置值"""
        if self._use_memory:
            self._memory_cache.set(key, value, expire)
        else:
            self._client.set(key, value, ex=expire)

    def get(self, key: str) -> Optional[str]:
        """获取值"""
        if self._use_memory:
            return self._memory_cache.get(key)
        return self._client.get(key)

    def lpush(self, key: str, value: str):
        """List 左侧推入"""
        if self._use_memory:
            self._memory_cache.lpush(key, value)
        else:
            self._client.lpush(key, value)

    def lrange(self, key: str, start: int, end: int) -> list:
        """获取 List 范围"""
        if self._use_memory:
            return self._memory_cache.lrange(key, start, end)
        return self._client.lrange(key, start, end)

    def delete(self, key: str):
        """删除键"""
        if self._use_memory:
            self._memory_cache.delete(key)
        else:
            self._client.delete(key)


redis_client = RedisClient()