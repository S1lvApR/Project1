import os
from contextlib import asynccontextmanager

from app.api.auth import router as auth_router
from app.api.health import router as health_router
from app.api.sign_analyzer import router as sign_analyzer_router
from app.api.chat_session import router as chat_session_router
from app.api.detection import router as detection_router
from app.config.settings import settings
from app.core.exceptions import register_exception_handlers
from app.middleware.request_logger import RequestLogMiddleware
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles


def init_minio():
    """初始化 MinIO 存储桶"""
    if not settings.minio_enabled:
        print("MinIO 已在当前运行模式中禁用")
        return

    from app.storage.minio_client import MinIOClient

    try:
        minio_client = MinIOClient()
        print(f"MinIO 存储桶 '{minio_client.bucket_name}' 初始化完成")
    except Exception as e:
        print(f"MinIO 初始化失败: {e}")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """应用生命周期管理"""
    # 启动时执行
    print("正在初始化服务...")

    from app.database.session import initialize_local_database

    initialize_local_database()
    init_minio()
    
    from app.services.scheduler_service import scheduler_service
    scheduler_service.start()

    from app.services.video_detection_service import video_detection_service

    migrated_sidecars = video_detection_service.migrate_legacy_sidecars()
    if migrated_sidecars:
        print(f"已迁移 {migrated_sidecars} 个旧视频状态文件")
    
    yield
    # 关闭时执行
    scheduler_service.shutdown()
    video_detection_service.shutdown()
    print("服务已关闭")


# 创建 FastAPI 实例
app = FastAPI(
    title="L Agent Platform",
    version="0.1.0",
    description="基于 YOLOv11 的目标检测智能体平台 API",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

# ── CORS 中间件配置 ──────────────────────────────────
# 允许前端跨域请求后端 API
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── 注册路由 ─────────────────────────────────────────
app.include_router(auth_router)
app.include_router(health_router)
app.include_router(sign_analyzer_router)
app.include_router(chat_session_router)
app.include_router(detection_router)

# ── 静态文件服务 ───────────────────────────────────────
# 用于访问上传的头像文件
uploads_dir = os.path.join(os.path.dirname(__file__), "uploads")
os.makedirs(uploads_dir, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=uploads_dir), name="uploads")
app.add_middleware(RequestLogMiddleware)


@app.get("/")
def root():
    return {
        "message": "欢迎使用 L Agent Platform",
        "version": "0.1.0",
        "docs": "/docs",
        "redoc": "/redoc",
    }


register_exception_handlers(app)

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        reload_excludes=["logs/", "*.log"],
    )
