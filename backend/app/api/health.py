from app.config.settings import settings
from app.core.logger import get_logger
from fastapi import APIRouter

logger = get_logger(__name__)

router = APIRouter(tags=["健康检查"])


@router.get("/api/health")
async def health_check():
    """
    基础健康检查

    用途：Docker liveness probe、负载均衡器探活
    特点：不检查外部依赖，只确认应用进程存活
    """
    return {
        "code": 200,
        "message": "ok",
        "data": {
            "status": "healthy",
            "app_name": settings.APP_NAME,
            "version": settings.APP_VERSION,
        },
    }


@router.get("/api/health/detail")
def health_check_detail():
    """
    详细健康检查

    用途：管理后台状态展示、运维监控
    特点：逐一检测 PostgreSQL、Redis、MinIO 连通性
    """
    services = {}

    # ── 检查 PostgreSQL ──────────────────────────────
    try:
        from app.database.session import SessionLocal
        from sqlalchemy import text

        db = SessionLocal()
        # 执行最简单的查询验证连接（SQLAlchemy 2.x 语法）
        db.execute(text("SELECT 1"))
        db.close()
        database_name = "SQLite" if settings.database_url.startswith("sqlite") else "PostgreSQL"
        services["database"] = {
            "status": "healthy",
            "message": f"{database_name} \u8fde\u63a5\u6b63\u5e38",
        }
    except Exception as e:
        services["database"] = {
            "status": "unhealthy",
            "message": f"PostgreSQL 连接失败: {str(e)}",
        }
        logger.error("PostgreSQL 健康检查失败: %s", str(e))

    # ── 检查 Redis ───────────────────────────────────
    if settings.redis_enabled:
        try:
            import redis

            r = redis.from_url(settings.REDIS_URL)
            r.ping()
            r.close()
            services["redis"] = {"status": "healthy", "message": "Redis 连接正常"}
        except Exception as e:
            services["redis"] = {
                "status": "unhealthy",
                "message": f"Redis 连接失败: {str(e)}",
            }
            logger.error("Redis 健康检查失败: %s", str(e))
    else:
        services["redis"] = {
            "status": "disabled",
            "message": "Redis 已在当前运行模式中禁用",
        }

    # ── 检查 MinIO ───────────────────────────────────
    if settings.minio_enabled:
        try:
            import urllib.request

            scheme = "https" if settings.MINIO_SECURE else "http"
            url = f"{scheme}://{settings.MINIO_ENDPOINT}/minio/health/live"
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status >= 400:
                    raise RuntimeError(f"MinIO health status: {response.status}")
            services["minio"] = {"status": "healthy", "message": "MinIO 连接正常"}
        except Exception as e:
            services["minio"] = {
                "status": "unhealthy",
                "message": f"MinIO 连接失败: {str(e)}",
            }
            logger.error("MinIO 健康检查失败: %s", str(e))
    else:
        services["minio"] = {
            "status": "disabled",
            "message": "MinIO 已在当前运行模式中禁用",
        }

    # ── 汇总状态 ─────────────────────────────────────
    all_healthy = all(
        service["status"] in {"healthy", "disabled"}
        for service in services.values()
    )

    return {
        "code": 200,
        "message": "ok",
        "data": {
            "status": "healthy" if all_healthy else "degraded",
            "app_name": settings.APP_NAME,
            "version": settings.APP_VERSION,
            "services": services,
        },
    }
