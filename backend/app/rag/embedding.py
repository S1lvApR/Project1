"""
文本向量化 — 将文本转换为高维向量

职责：
  - 调用 Embedding API 将文本块转换为向量
  - 支持通义千问 / OpenAI 两种 Embedding 模型
  - 批量处理提升效率

Embedding 模型选择：
  - 通义千问 text-embedding-v3（1024 维，推荐）
  - OpenAI text-embedding-3-small（1536 维）
"""

from typing import Optional

from app.config.settings import settings
from app.core.logger import get_logger

logger = get_logger(__name__)


class EmbeddingService:
    """文本向量化服务"""

    def __init__(self):
        self._client = None
        self._model = None
        self._init_client()

    def _init_client(self):
        """初始化 Embedding 客户端"""
        try:
            from openai import OpenAI

            # 优先使用通义千问 Embedding
            qwen_api_key = getattr(settings, "QWEN_API_KEY", "")
            if qwen_api_key and qwen_api_key != "your-qwen-api-key":
                self._client = OpenAI(
                    api_key=qwen_api_key,
                    base_url=getattr(
                        settings,
                        "QWEN_BASE_URL",
                        "https://dashscope.aliyuncs.com/compatible-mode/v1",
                    ),
                )
                self._model = getattr(settings, "EMBEDDING_MODEL", "text-embedding-v3")
            else:
                self._client = OpenAI(
                    api_key=getattr(settings, "OPENAI_API_KEY", ""),
                    base_url=getattr(settings, "OPENAI_BASE_URL", "https://api.openai.com/v1"),
                )
                self._model = getattr(settings, "EMBEDDING_MODEL", "text-embedding-3-small")

            logger.info("Embedding 服务初始化完成: model=%s", self._model)
        except Exception as e:
            logger.error("Embedding 服务初始化失败: %s", str(e))
            self._client = None

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        """
        批量将文本转换为向量

        Args:
            texts: 文本列表

        Returns:
            向量列表，每个向量是浮点数列表
        """
        if not self._client:
            logger.error("Embedding 客户端未初始化")
            return [[] for _ in texts]

        try:
            # 分批处理，每批最多 20 条
            all_embeddings = []
            batch_size = 20

            for i in range(0, len(texts), batch_size):
                batch = texts[i:i + batch_size]
                response = self._client.embeddings.create(
                    model=self._model,
                    input=batch,
                )
                batch_embeddings = [item.embedding for item in response.data]
                all_embeddings.extend(batch_embeddings)
                logger.debug("向量化批次 %d: %d 条文本", i // batch_size + 1, len(batch))

            logger.info("向量化完成: %d 条文本, 向量维度=%d",
                        len(texts), len(all_embeddings[0]) if all_embeddings else 0)
            return all_embeddings

        except Exception as e:
            logger.error("文本向量化失败: %s", str(e))
            return [[] for _ in texts]

    def embed_query(self, query: str) -> Optional[list[float]]:
        """
        将查询文本转换为向量

        Args:
            query: 查询文本

        Returns:
            向量（浮点数列表），失败返回 None
        """
        results = self.embed_texts([query])
        if results and results[0]:
            return results[0]
        return None


embedding_service = EmbeddingService()