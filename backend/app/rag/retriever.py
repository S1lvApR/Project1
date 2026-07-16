"""
语义检索器 — 将 RAG 流程串联为完整管道

职责：
  - 知识库初始化（加载文档 → 分块 → 向量化 → 存储）
  - 语义检索（查询 → 向量化 → Pgvector 检索 → 格式化结果）
  - 知识库管理（重建索引、清空、统计）

使用方式：
  from app.rag.retriever import knowledge_retriever

  # 初始化知识库（首次启动时调用）
  knowledge_retriever.build_index()

  # 检索
  results = knowledge_retriever.search("什么是 IoU？", top_k=3)
"""

from app.core.logger import get_logger
from app.rag.document_loader import document_loader
from app.rag.embedding import embedding_service
from app.vectorstore.pgvector_client import pgvector_client

logger = get_logger(__name__)


class KnowledgeRetriever:
    """知识检索器"""

    def __init__(self):
        self._index_built = False

    def build_index(self, force_rebuild: bool = False):
        """
        构建知识库索引

        流程：加载文档 → 文本分块 → 向量化 → 存入 Pgvector

        Args:
            force_rebuild: 是否强制重建（先清空再构建）
        """
        if self._index_built and not force_rebuild:
            count = pgvector_client.count()
            if count > 0:
                logger.info("知识库索引已存在 (%d 条)，跳过构建", count)
                return

        logger.info("开始构建知识库索引...")

        # 1. 初始化 Pgvector 表
        pgvector_client.init_table()

        # 2. 如果需要强制重建，先清空
        if force_rebuild:
            pgvector_client.clear()

        # 3. 加载文档
        documents = document_loader.load_documents()
        if not documents:
            logger.warning("知识库中没有文档")
            return

        # 4. 文本分块
        chunks = document_loader.split_documents(documents)
        if not chunks:
            logger.warning("文档分块后为空")
            return

        # 5. 批量向量化
        texts = [chunk["content"] for chunk in chunks]
        metadatas = [chunk["metadata"] for chunk in chunks]
        embeddings = embedding_service.embed_texts(texts)

        # 过滤掉向量化失败的条目
        valid_indices = [i for i, emb in enumerate(embeddings) if emb]
        if not valid_indices:
            logger.error("所有文本向量化均失败")
            return

        valid_texts = [texts[i] for i in valid_indices]
        valid_embeddings = [embeddings[i] for i in valid_indices]
        valid_metadatas = [metadatas[i] for i in valid_indices]

        # 6. 存入 Pgvector
        pgvector_client.insert_embeddings(valid_texts, valid_embeddings, valid_metadatas)

        self._index_built = True
        logger.info(
            "知识库索引构建完成: %d 个文档 → %d 个文本块 → %d 条向量",
            len(documents), len(chunks), len(valid_texts),
        )

    def search(self, query: str, top_k: int = 3) -> list[dict]:
        """
        语义检索

        Args:
            query: 查询文本
            top_k: 返回最相似的前 K 条结果

        Returns:
            检索结果列表 [{"content": "...", "metadata": {...}, "similarity": 0.95}, ...]
        """
        # 确保索引已构建
        if not self._index_built:
            self.build_index()

        # 将查询文本向量化
        query_embedding = embedding_service.embed_query(query)
        if not query_embedding:
            logger.error("查询向量化失败: %s", query)
            return []

        # 在 Pgvector 中检索
        results = pgvector_client.search(query_embedding, top_k=top_k)

        return results

    def format_context(self, results: list[dict]) -> str:
        """
        将检索结果格式化为 LLM 可用的上下文文本

        Args:
            results: 检索结果列表

        Returns:
            格式化后的上下文字符串
        """
        if not results:
            return "（知识库中暂无相关内容）"

        parts = []
        for i, r in enumerate(results, 1):
            source = r.get("metadata", {}).get("source", "未知")
            similarity = r.get("similarity", 0)
            parts.append(
                f"[知识片段 {i}] (来源: {source}, 相似度: {similarity:.2f})\n"
                f"{r['content']}"
            )

        return "\n\n---\n\n".join(parts)

    def get_stats(self) -> dict:
        """获取知识库统计信息"""
        count = pgvector_client.count()
        return {
            "total_chunks": count,
            "index_built": self._index_built or count > 0,
        }


knowledge_retriever = KnowledgeRetriever()