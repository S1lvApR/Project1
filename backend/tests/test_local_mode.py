from pathlib import Path

import pytest
from sqlalchemy import inspect
from sqlalchemy.orm import sessionmaker

from app import database as database_package
from app.config.settings import Settings
from app.database import session as database_session
from app.database.session import build_engine, initialize_local_database
from app.entity import db_models  # noqa: F401


def make_local_settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None,
        APP_MODE="local",
        DATABASE_URL=f"sqlite:///{tmp_path / 'local.db'}",
    )


def test_local_settings_disable_optional_services_by_default():
    settings = Settings(_env_file=None, APP_MODE="local")

    assert settings.is_local is True
    assert settings.database_url == "sqlite:///./data/local.db"
    assert settings.redis_enabled is False
    assert settings.minio_enabled is False


def test_settings_reject_bootstrap_jwt_marker():
    with pytest.raises(ValueError, match="generated-by-bootstrap"):
        Settings(_env_file=None, JWT_SECRET_KEY="generated-by-bootstrap")


def test_production_settings_keep_postgres_and_optional_services():
    settings = Settings(_env_file=None, APP_MODE="production")

    assert settings.is_local is False
    assert settings.database_url.startswith("postgresql://")
    assert settings.redis_enabled is True
    assert settings.minio_enabled is True


def test_explicit_database_url_overrides_profile_default(tmp_path):
    database_url = f"sqlite:///{tmp_path / 'override.db'}"
    settings = Settings(
        _env_file=None,
        APP_MODE="production",
        DATABASE_URL=database_url,
    )

    assert settings.database_url == database_url


def test_local_yolo_settings_resolve_project_paths():
    settings = Settings(_env_file=None, APP_MODE="local")

    assert settings.yolo_model_path.is_absolute()
    assert settings.yolo_model_path.name == "best.pt"
    assert settings.detection_output_path.is_absolute()
    assert settings.detection_output_path.name == "detections"
    assert settings.YOLO_DEVICE == "auto"
    assert settings.YOLO_CONFIDENCE == 0.25
    assert settings.YOLO_IOU == 0.45
    assert settings.YOLO_IMAGE_SIZE == 1280
    assert settings.VIDEO_SPEED_REFINEMENT_PL40_MIN_CONFIDENCE == 0.75
    assert settings.YOLO_MAX_BATCH_IMAGES == 20
    assert settings.YOLO_MAX_IMAGE_BYTES == 10 * 1024 * 1024
    assert settings.gtsrb_model_path.is_absolute()
    assert settings.gtsrb_model_path.name == "best.pt"
    assert settings.GTSRB_DEVICE == "auto"
    assert settings.GTSRB_IMAGE_SIZE == 128
    assert settings.GTSRB_CROP_MAX_DIMENSION == 512


def test_local_engine_creates_parent_directory_and_uses_sqlite(tmp_path):
    database_path = tmp_path / "nested" / "local.db"
    settings = Settings(
        _env_file=None,
        APP_MODE="local",
        DATABASE_URL=f"sqlite:///{database_path}",
    )

    engine = build_engine(settings)

    assert engine.url.drivername == "sqlite"
    assert database_path.parent.is_dir()
    with engine.connect() as connection:
        assert connection.exec_driver_sql("SELECT 1").scalar_one() == 1


def test_local_database_initialization_creates_tables_only_for_local_mode(tmp_path):
    local_settings = make_local_settings(tmp_path)
    local_engine = build_engine(local_settings)

    initialize_local_database(local_settings, local_engine)

    assert inspect(local_engine).get_table_names()

    production_db = tmp_path / "production.db"
    production_settings = Settings(
        _env_file=None,
        APP_MODE="production",
        DATABASE_URL=f"sqlite:///{production_db}",
    )
    production_engine = build_engine(production_settings)

    initialize_local_database(production_settings, production_engine)

    assert inspect(production_engine).get_table_names() == []


def test_optional_services_are_disabled_in_local_health(monkeypatch, tmp_path):
    from app.api import health

    local_settings = make_local_settings(tmp_path)
    local_engine = build_engine(local_settings)
    initialize_local_database(local_settings, local_engine)
    local_session = sessionmaker(bind=local_engine)

    monkeypatch.setattr(health, "settings", local_settings)
    monkeypatch.setattr(database_session, "SessionLocal", local_session)
    monkeypatch.setattr(database_package, "session", database_session, raising=False)

    result = health.health_check_detail()
    services = result["data"]["services"]

    assert result["data"]["status"] == "healthy"
    assert services["database"]["status"] == "healthy"
    assert services["database"]["message"] == "SQLite 连接正常"
    assert services["redis"]["status"] == "disabled"
    assert services["minio"]["status"] == "disabled"
