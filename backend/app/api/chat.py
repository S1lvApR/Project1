"""
聊天 API 路由（使用新的 DetectionAgent）

接口列表：
  - POST /api/chat/message    发送消息（流式响应）
  - POST /api/chat/text       发送消息（非流式响应）
"""

from typing import AsyncGenerator

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.api.auth import get_current_user
from app.agent.detection_agent import detection_agent
from app.database.session import get_db
from app.entity.db_models import User
from app.services.chat_session_service import ChatSessionService

router = APIRouter(prefix="/api/chat", tags=["聊天"])


class ChatRequest(BaseModel):
    session_uuid: str
    message: str


class ChatResponse(BaseModel):
    success: bool
    message: str
    response: str = None
    needs_upload: bool = False


async def chat_stream_generator(
    request: ChatRequest,
    user_id: int,
) -> AsyncGenerator[str, None]:
    """生成 SSE 流式响应"""
    import logging
    logger = logging.getLogger(__name__)
    logger.info(f"开始处理聊天消息: user_id={user_id}, session_id={request.session_uuid}, message={request.message[:50]}")
    
    async for event in detection_agent.chat_stream(
        message=request.message,
        user_id=user_id,
        session_id=request.session_uuid,
    ):
        import json
        logger.debug(f"发送 SSE 事件: type={event.get('type')}, content={str(event.get('content', ''))[:30]}")
        yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


@router.post("/message")
async def chat_message(
    request: ChatRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """发送消息（流式响应）"""
    session = ChatSessionService.get_session_by_uuid(db, request.session_uuid)
    if not session or session.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="会话不存在或无权访问")

    ChatSessionService.add_message(db, session.id, "user", request.message)

    return StreamingResponse(
        chat_stream_generator(request, current_user.id),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        },
    )


@router.post("/text")
async def chat_text(
    request: ChatRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """发送消息（非流式响应，兼容旧接口）"""
    session = ChatSessionService.get_session_by_uuid(db, request.session_uuid)
    if not session or session.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="会话不存在或无权访问")

    try:
        result = await detection_agent.chat(request.message)

        ChatSessionService.add_message(db, session.id, "user", request.message)
        ChatSessionService.add_message(db, session.id, "assistant", result["output"])

        needs_upload = result["output"].strip() == "好的，请在下方出现的卡片中上传您需要识别的图片、文件夹或ZIP压缩包。"

        return ChatResponse(
            success=True,
            message="消息发送成功",
            response=result["output"],
            needs_upload=needs_upload,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"聊天服务出错: {str(e)}")