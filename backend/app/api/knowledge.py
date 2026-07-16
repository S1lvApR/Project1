"""
知识库管理 API 路由

接口列表：
  - POST /api/knowledge/build    构建/重建知识库索引
  - GET  /api/knowledge/stats    知识库统计信息
  - POST /api/knowledge/search   手动测试检索
"""

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.api.auth import get_current_user
from app.core.logger import get_logger
from app.rag.retriever import knowledge_retriever

logger = get_logger(__name__)

router = APIRouter(prefix="/api/knowledge", tags=["知识库管理"])


class SearchRequest(BaseModel):
    query: str
    top_k: int = 3


@router.post("/build", summary="构建知识库索引")
async def build_index(
    force_rebuild: bool = False,
    current_user=Depends(get_current_user),
):
    """构建或重建知识库索引"""
    knowledge_retriever.build_index(force_rebuild=force_rebuild)
    stats = knowledge_retriever.get_stats()
    return {"message": "知识库索引构建完成", "stats": stats}


@router.get("/stats", summary="知识库统计")
async def get_stats(current_user=Depends(get_current_user)):
    """获取知识库统计信息"""
    return knowledge_retriever.get_stats()


@router.post("/search", summary="测试检索")
async def search_knowledge(
    request: SearchRequest,
    current_user=Depends(get_current_user),
):
    """手动测试知识库检索"""
    results = knowledge_retriever.search(request.query, top_k=request.top_k)
    return {
        "query": request.query,
        "results": results,
        "count": len(results),
    }