"""
向量存储客户端 — 支持 PostgreSQL pgvector 和 SQLite 内存降级

职责：
  - 创建和管理 knowledge_embeddings 表
  - 插入/更新向量数据
  - 余弦相似度检索
  - 表结构初始化和迁移

表结构：
  knowledge_embeddings (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,          -- 文本块内容
    metadata JSONB/TEXT,            -- 元数据（来源、标题等）
    embedding vector/TEXT,          -- 向量（维度取决于 Embedding 模型）
    created_at TIMESTAMP DEFAULT NOW()
  )

依赖：
  - PostgreSQL 需要安装 pgvector 扩展
  - SQLite 使用内存向量存储作为降级方案
"""

import json
from typing import Optional

from sqlalchemy import text

from app.config.settings import settings
from app.core.logger import get_logger
from app.database.session import SessionLocal

logger = get_logger(__name__)

EMBEDDING_DIM = 1024


class PgvectorClient:
    """向量存储客户端"""

    def __init__(self):
        self._initialized = False
        self._is_sqlite = False
        self._memory_store = []

        if settings.DATABASE_URL.startswith("sqlite"):
            self._is_sqlite = True
            logger.info("检测到 SQLite 数据库，使用内存向量存储作为降级方案")

    def _cosine_similarity(self, vec1: list[float], vec2: list[float]) -> float:
        """计算两个向量的余弦相似度"""
        dot = sum(a * b for a, b in zip(vec1, vec2))
        mag1 = sum(a * a for a in vec1) ** 0.5
        mag2 = sum(b * b for b in vec2) ** 0.5
        if mag1 == 0 or mag2 == 0:
            return 0.0
        return dot / (mag1 * mag2)

    def init_table(self):
        """初始化向量表和索引"""
        if self._initialized:
            return

        if self._is_sqlite:
            self._initialized = True
            logger.info("SQLite 模式：使用内存向量存储")
            return

        db = SessionLocal()
        try:
            try:
                db.execute(text("CREATE EXTENSION IF NOT EXISTS vector;"))
            except Exception:
                logger.warning("无法创建 vector 扩展，可能不是 PostgreSQL 数据库")

            db.execute(text("""
                CREATE TABLE IF NOT EXISTS knowledge_embeddings (
                    id SERIAL PRIMARY KEY,
                    content TEXT NOT NULL,
                    metadata JSONB DEFAULT '{}'::jsonb,
                    embedding vector(1024),
                    created_at TIMESTAMP DEFAULT NOW()
                );
            """))
            db.commit()
            self._initialized = True
            logger.info("Pgvector 表初始化完成")
        except Exception as e:
            db.rollback()
            logger.error("Pgvector 初始化失败: %s", str(e))
        finally:
            db.close()

    def insert_embeddings(
        self,
        contents: list[str],
        embeddings: list[list[float]],
        metadatas: list[dict] = None,
    ):
        """批量插入向量数据"""
        if not contents or not embeddings:
            return

        if self._is_sqlite:
            for i in range(len(contents)):
                self._memory_store.append({
                    "content": contents[i],
                    "metadata": metadatas[i] if metadatas and i < len(metadatas) else {},
                    "embedding": embeddings[i],
                })
            logger.info("SQLite 模式：插入 %d 条向量数据到内存", len(contents))
            return

        db = SessionLocal()
        try:
            for i in range(len(contents)):
                metadata = metadatas[i] if metadatas and i < len(metadatas) else {}
                embedding_str = "[" + ",".join(str(v) for v in embeddings[i]) + "]"

                db.execute(
                    text(
                        "INSERT INTO knowledge_embeddings (content, metadata, embedding) "
                        "VALUES (:content, :metadata::jsonb, :embedding::vector)"
                    ),
                    {
                        "content": contents[i],
                        "metadata": json.dumps(metadata, ensure_ascii=False),
                        "embedding": embedding_str,
                    },
                )

            db.commit()
            logger.info("插入 %d 条向量数据", len(contents))
        except Exception as e:
            db.rollback()
            logger.error("插入向量数据失败: %s", str(e))
        finally:
            db.close()

    def search(
        self,
        query_embedding: list[float],
        top_k: int = 3,
        filter_metadata: Optional[dict] = None,
    ) -> list[dict]:
        """余弦相似度检索"""
        if self._is_sqlite:
            results = []
            for item in self._memory_store:
                similarity = self._cosine_similarity(query_embedding, item["embedding"])
                results.append({
                    "content": item["content"],
                    "metadata": item["metadata"],
                    "similarity": round(similarity, 4),
                })

            results.sort(key=lambda x: x["similarity"], reverse=True)
            logger.info(
                "SQLite 模式：向量检索完成: top_k=%d, 最高相似度=%.4f",
                top_k,
                results[0]["similarity"] if results else 0,
            )
            return results[:top_k]

        db = SessionLocal()
        try:
            embedding_str = "[" + ",".join(str(v) for v in query_embedding) + "]"

            sql = """
                SELECT
                    content,
                    metadata,
                    1 - (embedding <=> :query::vector) AS similarity
                FROM knowledge_embeddings
                ORDER BY embedding <=> :query::vector
                LIMIT :top_k
            """

            results = db.execute(
                text(sql),
                {"query": embedding_str, "top_k": top_k},
            ).fetchall()

            search_results = []
            for row in results:
                search_results.append({
                    "content": row[0],
                    "metadata": row[1] if isinstance(row[1], dict) else {},
                    "similarity": round(float(row[2]), 4),
                })

            logger.info(
                "向量检索完成: top_k=%d, 最高相似度=%.4f",
                top_k,
                search_results[0]["similarity"] if search_results else 0,
            )
            return search_results

        except Exception as e:
            logger.error("向量检索失败: %s", str(e))
            return []
        finally:
            db.close()

    def count(self) -> int:
        """获取向量表中的记录数"""
        if self._is_sqlite:
            return len(self._memory_store)

        db = SessionLocal()
        try:
            result = db.execute(text("SELECT COUNT(*) FROM knowledge_embeddings")).scalar()
            return result or 0
        except Exception:
            return 0
        finally:
            db.close()

    def clear(self):
        """清空向量表"""
        if self._is_sqlite:
            self._memory_store.clear()
            logger.info("SQLite 模式：内存向量存储已清空")
            return

        db = SessionLocal()
        try:
            db.execute(text("DELETE FROM knowledge_embeddings"))
            db.commit()
            logger.info("向量表已清空")
        except Exception as e:
            db.rollback()
            logger.error("清空向量表失败: %s", str(e))
        finally:
            db.close()


pgvector_client = PgvectorClient()