from pathlib import Path

from app.config.settings import settings
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker


def build_engine(database_settings):
    """Build a SQLAlchemy engine for either the local or production profile."""
    database_url = database_settings.database_url

    if database_url.startswith("sqlite"):
        database_path = database_url.split("///", 1)[-1]
        if database_path and database_path != ":memory:":
            Path(database_path).expanduser().parent.mkdir(parents=True, exist_ok=True)
        return create_engine(
            database_url,
            connect_args={"check_same_thread": False},
            echo=database_settings.DEBUG,
        )

    return create_engine(
        database_url,
        pool_size=10,
        max_overflow=20,
        pool_pre_ping=True,
        echo=database_settings.DEBUG,
    )


engine = build_engine(settings)

# 会话⼯⼚
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)
# ORM 模型的基类，所有模型都继承⾃它
Base = declarative_base()


def initialize_local_database(database_settings=settings, database_engine=engine):
    """Create ORM tables only for the explicitly selected local profile."""
    if not database_settings.is_local:
        return

    from app.entity import db_models  # noqa: F401

    Base.metadata.create_all(bind=database_engine)


def get_db():
    """
    获取数据库会话的依赖注⼊函数
    在 FastAPI 路由中通过 Depends(get_db) 使⽤
    ⽤法示例：
        @router.get("/xxx")
        def my_api(db: Session = Depends(get_db)):
            ...
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
