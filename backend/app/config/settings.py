from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


BACKEND_DIR = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    # ── RAG / Embedding 配置 ──────────────────────────
    EMBEDDING_MODEL: str = "text-embedding-v3"   # 通义千问 Embedding 模型
    EMBEDDING_DIM: int = 1024                     # 向量维度（text-embedding-v3=1024, text-embedding-3-small=1536）
    RAG_CHUNK_SIZE: int = 500                     # 文档分块大小
    RAG_CHUNK_OVERLAP: int = 50                   # 分块重叠字符数
    RAG_TOP_K: int = 3                            # 检索返回 Top-K 条
    # ── 应用基础配置 ──────────────────────────────────
    APP_NAME: str = "RSOD Agent Platform"
    APP_VERSION: str = "0.1.0"
    DEBUG: bool = True
    LOG_LEVEL: str = "INFO"
    APP_MODE: str = "production"
    # ── 数据库配置 ────────────────────────────────────
    DB_HOST: str = "localhost"
    DB_PORT: int = 5432
    DB_NAME: str = "L_agent"
    DB_USER: str = "Ladmin"
    DB_PASSWORD: str = "Ladmin"
    DATABASE_URL: str | None = None
    LOCAL_DATABASE_PATH: str = "./data/local.db"
    REDIS_ENABLED: bool | None = None
    MINIO_ENABLED: bool | None = None
    # ── 本地 YOLO 推理配置 ────────────────────────────
    YOLO_MODEL_PATH: str = "../training/runs/tt100k_yolo11n_gpu/weights/best.pt"
    YOLO_MODEL_NAME: str = "tt100k-yolo11n"
    YOLO_MODEL_TYPE: str = "yolov11n"
    YOLO_DEVICE: str = "auto"
    YOLO_CANONICALIZE_TT100K_CLASSES: bool = True
    YOLO_USE_SAHI: bool = False
    YOLO_SAHI_SLICE_HEIGHT: int = Field(default=512, ge=128)
    YOLO_SAHI_SLICE_WIDTH: int = Field(default=512, ge=128)
    YOLO_SAHI_OVERLAP_RATIO: float = Field(default=0.2, ge=0.0, lt=1.0)
    YOLO_SAHI_MODEL_IMAGE_SIZE: int = Field(default=640, ge=32)
    YOLO_SAHI_STANDARD_PREDICTION: bool = True
    YOLO_CONFIDENCE: float = Field(default=0.25, ge=0.0, le=1.0)
    YOLO_IOU: float = Field(default=0.45, ge=0.0, le=1.0)
    YOLO_IMAGE_SIZE: int = Field(default=640, ge=32)
    YOLO_MAX_BATCH_IMAGES: int = Field(default=20, ge=1)
    YOLO_MAX_IMAGE_BYTES: int = Field(default=10 * 1024 * 1024, ge=1)
    VIDEO_MAX_BYTES: int = Field(default=50 * 1024 * 1024, ge=1)
    VIDEO_FRAME_SAMPLE_RATE: int = Field(default=5, ge=1)
    VIDEO_MAX_FRAMES: int = Field(default=50, ge=1)
    VIDEO_WORKERS: int = Field(default=2, ge=1, le=8)
    VIDEO_MAX_PENDING_TASKS: int = Field(default=4, ge=1, le=32)
    VIDEO_PROGRESS_TTL_SECONDS: int = Field(default=3600, ge=1)
    VIDEO_TEMP_DIR: str = "./uploads/videos"
    VIDEO_STATUS_DIR: str = "./data/video_status"
    CAMERA_CPU_IMAGE_SIZE: int = Field(default=416, ge=32)
    CAMERA_GPU_IMAGE_SIZE: int = Field(default=640, ge=32)
    CAMERA_MAX_FRAME_BYTES: int = Field(default=2 * 1024 * 1024, ge=1)
    GTSRB_MODEL_PATH: str = "../training/runs/gtsrb_yolo11n_cls_gpu_final/weights/best.pt"
    GTSRB_DEVICE: str = "auto"
    GTSRB_IMAGE_SIZE: int = Field(default=128, ge=32)
    GTSRB_CROP_MAX_DIMENSION: int = Field(default=512, ge=32)
    DETECTION_OUTPUT_DIR: str = "./uploads/detections"
    # ── 日志配置 ──────────────────────────────────────
    LOG_DIR: str = "logs"  # 日志目录（相对于 backend/）
    LOG_MAX_BYTES: int = 10 * 1024 * 1024  # 单文件最大 10MB
    LOG_BACKUP_COUNT: int = 5  # 保留 5 份历史日志

    @property
    def is_local(self) -> bool:
        return self.APP_MODE.strip().lower() == "local"

    @property
    def database_url(self) -> str:
        if self.DATABASE_URL and self.DATABASE_URL.strip():
            return self.DATABASE_URL
        if self.is_local:
            return f"sqlite:///{self.LOCAL_DATABASE_PATH}"
        return f"postgresql://{self.DB_USER}:{self.DB_PASSWORD}@{self.DB_HOST}:{self.DB_PORT}/{self.DB_NAME}"

    @staticmethod
    def _resolve_backend_path(value: str) -> Path:
        path = Path(value).expanduser()
        return path.resolve() if path.is_absolute() else (BACKEND_DIR / path).resolve()

    @property
    def yolo_model_path(self) -> Path:
        return self._resolve_backend_path(self.YOLO_MODEL_PATH)

    @property
    def gtsrb_model_path(self) -> Path:
        return self._resolve_backend_path(self.GTSRB_MODEL_PATH)

    @property
    def detection_output_path(self) -> Path:
        return self._resolve_backend_path(self.DETECTION_OUTPUT_DIR)

    @property
    def video_temp_path(self) -> Path:
        return self._resolve_backend_path(self.VIDEO_TEMP_DIR)

    @property
    def video_status_path(self) -> Path:
        return self._resolve_backend_path(self.VIDEO_STATUS_DIR)

    # ── Redis 配置 ────────────────────────────────────
    REDIS_HOST: str = "localhost"
    REDIS_PORT: int = 6379

    @property
    def REDIS_URL(self) -> str:
        """构造 Redis 连接字符串"""
        return f"redis://{self.REDIS_HOST}:{self.REDIS_PORT}/0"

    @property
    def redis_enabled(self) -> bool:
        return self.REDIS_ENABLED if self.REDIS_ENABLED is not None else not self.is_local

    # ── MinIO 配置 ────────────────────────────────────
    MINIO_ENDPOINT: str = "localhost:9000"
    MINIO_ACCESS_KEY: str = "minioadmin"
    MINIO_SECRET_KEY: str = "minioadmin"
    MINIO_BUCKET: str = "images"
    MINIO_SECURE: bool = False

    @property
    def minio_enabled(self) -> bool:
        return self.MINIO_ENABLED if self.MINIO_ENABLED is not None else not self.is_local
    # ── JWT 认证配置 ──────────────────────────────────
    JWT_SECRET_KEY: str = "your-super-secret-key-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30

    @field_validator("JWT_SECRET_KEY")
    @classmethod
    def reject_bootstrap_secret_marker(cls, value: str) -> str:
        if value.strip() == "generated-by-bootstrap":
            raise ValueError("JWT_SECRET_KEY must not use generated-by-bootstrap")
        return value
    # ── 百度OCR API 配置 ──────────────────────────────
    BAIDU_API_KEY: str = "your-baidu-api-key"
    BAIDU_SECRET_KEY: str = "your-baidu-secret-key"
    # ── 百炼智能体配置 ────────────────────────────────
    DASHSCOPE_API_KEY: str = "your-dashscope-api-key"
    DASHSCOPE_BASE_URL: str = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    DASHSCOPE_MODEL: str = "qwen-turbo"
    # ── 通义千问 API 配置（新智能体使用）───────────────────
    QWEN_API_KEY: str = "your-qwen-api-key"
    QWEN_BASE_URL: str = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    QWEN_MODEL: str = "qwen3.7-plus"

    # ── CORS 配置 ────────────────────────────────────
    ALLOWED_ORIGINS: str = (
        "http://localhost:3000,http://localhost:5173,http://localhost:8080"
    )

    @property
    def cors_origins_list(self) -> list:
        """将 CORS 配置字符串转为列表"""
        return [origin.strip() for origin in self.ALLOWED_ORIGINS.split(",")]

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        extra = "ignore"

    # 创建全局单例，其他模块直接 import 使⽤


settings = Settings()
