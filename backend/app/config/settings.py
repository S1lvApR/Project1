from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # ── 应用基础配置 ──────────────────────────────────
    APP_NAME: str = "111"
    APP_VERSION: str = "0.1.0"
    DEBUG: bool = True
    LOG_LEVEL: str = "INFO"
    # ── 数据库配置 ────────────────────────────────────
    DB_HOST: str = "localhost"
    DB_PORT: int = 5432
    DB_NAME: str = "L_agent"
    DB_USER: str = "Ladmin"
    DB_PASSWORD: str = "Ladmin"
    # ── 日志配置 ──────────────────────────────────────
    LOG_DIR: str = "logs"  # 日志目录（相对于 backend/）
    LOG_MAX_BYTES: int = 10 * 1024 * 1024  # 单文件最大 10MB
    LOG_BACKUP_COUNT: int = 5  # 保留 5 份历史日志

    @property
    def DATABASE_URL(self) -> str:
        return f"postgresql://{self.DB_USER}:{self.DB_PASSWORD}@{self.DB_HOST}:{self.DB_PORT}/{self.DB_NAME}"

    # ── Redis 配置 ────────────────────────────────────
    REDIS_HOST: str = "localhost"
    REDIS_PORT: int = 6379

    @property
    def REDIS_URL(self) -> str:
        """构造 Redis 连接字符串"""
        return f"redis://{self.REDIS_HOST}:{self.REDIS_PORT}/0"

    # ── MinIO 配置 ────────────────────────────────────
    MINIO_ENDPOINT: str = "localhost:9000"
    MINIO_ACCESS_KEY: str = "minioadmin"
    MINIO_SECRET_KEY: str = "minioadmin"
    MINIO_BUCKET: str = "images"
    MINIO_SECURE: bool = False
    # ── JWT 认证配置 ──────────────────────────────────
    JWT_SECRET_KEY: str = "your-super-secret-key-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    # ── 百度OCR API 配置 ──────────────────────────────
    BAIDU_API_KEY: str = "your-baidu-api-key"
    BAIDU_SECRET_KEY: str = "your-baidu-secret-key"
    # ── SignAnalyzer 智能体配置 ────────────────────
    SIGN_ANALYZER_API_KEY: str = "your-sign-analyzer-api-key"
    SIGN_ANALYZER_API_URL: str = "https://api.example.com/sign-analyzer"
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
