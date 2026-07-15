from app.config.settings import settings
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

# 创建数据库引擎
# pool_pre_ping=True：每次从连接池取连接前先测试是否可⽤
engine = create_engine(
    settings.DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
    echo=settings.DEBUG,  # DEBUG 模式下打印 SQL 语句
)
# 会话⼯⼚
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)
# ORM 模型的基类，所有模型都继承⾃它
Base = declarative_base()


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
