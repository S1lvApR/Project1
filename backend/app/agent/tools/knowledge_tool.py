"""
知识库工具 — Agent 可调用的 RAG 检索工具

工具列表：
  - search_knowledge: 语义检索知识库
"""

import json

from langchain_core.tools import tool

from app.core.logger import get_logger
from app.rag.retriever import knowledge_retriever

logger = get_logger(__name__)


@tool
def search_knowledge(query: str, top_k: int = 3) -> str:
    """搜索遥感目标检测知识库，获取专业领域的知识内容。

    当用户询问专业知识问题时使用此工具，例如：
    - "什么是 IoU？"
    - "YOLOv11 有哪些改进？"
    - "mAP 是怎么计算的？"
    - "遥感图像有什么特点？"
    - "什么是 NMS 非极大值抑制？"

    Args:
        query: 用户的问题或关键词
        top_k: 返回最相关的前 K 条知识片段，默认 3 条

    Returns:
        JSON 字符串，包含检索到的知识片段（内容、来源、相似度）
    """
    try:
        results = knowledge_retriever.search(query, top_k=top_k)

        if not results:
            return json.dumps({
                "answer": "知识库中暂无相关内容",
                "sources": [],
            }, ensure_ascii=False)

        formatted = []
        for r in results:
            formatted.append({
                "content": r["content"][:300],  # 截取前 300 字符，避免过长
                "source": r.get("metadata", {}).get("source", "未知"),
                "similarity": r.get("similarity", 0),
            })

        return json.dumps({
            "knowledge": formatted,
            "count": len(formatted),
        }, ensure_ascii=False)
    except Exception as e:
        logger.error("知识检索失败: %s", str(e))
        return json.dumps({"error": f"检索失败: {str(e)}"}, ensure_ascii=False)


# 知识工具列表
KNOWLEDGE_TOOLS = [
    search_knowledge,
]