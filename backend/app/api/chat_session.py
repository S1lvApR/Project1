from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.api.auth import get_current_user
from app.entity.db_models import User
from app.services.chat_session_service import ChatSessionService

router = APIRouter(prefix="/api/chat-sessions", tags=["chat-sessions"])


@router.get("")
async def get_user_sessions(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    sessions = ChatSessionService.get_sessions_by_user(db, current_user.id)
    return {
        "success": True,
        "data": [ChatSessionService.convert_session_to_dict(session) for session in sessions],
    }


@router.post("")
async def create_session(
    title: str = "New Chat",
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.create_session(db, current_user.id, title)
    return {
        "success": True,
        "data": ChatSessionService.convert_session_to_dict(session),
    }


@router.get("/{session_uuid}")
async def get_session_detail(
    session_uuid: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        return {"success": False, "message": "会话不存在或无权访问"}
    return {
        "success": True,
        "data": ChatSessionService.convert_session_to_dict(session),
    }


@router.post("/{session_uuid}/messages")
async def add_message(
    session_uuid: str,
    role: str,
    content: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        return {"success": False, "message": "会话不存在或无权访问"}
    
    message = ChatSessionService.add_message(db, session.id, role, content)
    return {
        "success": True,
        "data": ChatSessionService.convert_message_to_dict(message) if message else None,
    }


@router.put("/{session_uuid}/title")
async def update_title(
    session_uuid: str,
    title: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        return {"success": False, "message": "会话不存在或无权访问"}
    
    updated_session = ChatSessionService.update_session_title(db, session.id, title)
    return {
        "success": True,
        "data": ChatSessionService.convert_session_to_dict(updated_session),
    }


@router.delete("/{session_uuid}")
async def delete_session(
    session_uuid: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        return {"success": False, "message": "会话不存在或无权访问"}
    
    success = ChatSessionService.delete_session(db, session.id)
    return {
        "success": success,
        "message": "删除成功" if success else "删除失败",
    }