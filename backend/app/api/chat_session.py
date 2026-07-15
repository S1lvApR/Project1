import os
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session
from typing import List, Dict, Optional

class MessageRequest(BaseModel):
    role: str
    content: str
    video_result: Optional[Dict] = None

from app.database.session import get_db
from app.api.auth import get_current_user
from app.entity.db_models import User
from app.services.chat_session_service import ChatSessionService
from app.services.ai_service import ai_service
from app.services.sign_analyzer_service import sign_analyzer_service

router = APIRouter(prefix="/chat-sessions", tags=["chat-sessions"])

UPLOADS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "uploads")
if not os.path.exists(UPLOADS_DIR):
    os.makedirs(UPLOADS_DIR)


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
    request_data: MessageRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        return {"success": False, "message": "会话不存在或无权访问"}
    
    message = ChatSessionService.add_message(
        db, session.id, request_data.role, request_data.content, 
        user=current_user, video_result=request_data.video_result
    )
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


class ChatRequest(BaseModel):
    content: str
    image_base64: Optional[str] = None

@router.post("/{session_uuid}/chat")
async def chat_with_ai(
    session_uuid: str,
    request_data: ChatRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    content = request_data.content
    image_base64 = request_data.image_base64
    session = ChatSessionService.get_session_by_uuid(db, session_uuid)
    if not session or session.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="会话不存在或无权访问")

    if content.startswith("/"):
        message = ChatSessionService.add_message(db, session.id, "user", content, user=current_user)
        return {
            "success": True,
            "data": ChatSessionService.convert_message_to_dict(message) if message else None,
        }

    image_url = None
    sign_result = None
    
    if image_base64:
        try:
            import base64
            image_bytes = base64.b64decode(image_base64)
            
            ext = ".png"
            if image_base64.startswith("iVBORw0KGgo"):
                ext = ".png"
            elif image_base64.startswith("/9j/"):
                ext = ".jpg"
            
            filename = f"{uuid4().hex}{ext}"
            save_path = os.path.join(UPLOADS_DIR, filename)
            
            with open(save_path, "wb") as f:
                f.write(image_bytes)
            
            image_url = f"/uploads/{filename}"
            
            sign_result = sign_analyzer_service.analyze_sign(image_bytes)
            
            if sign_result["success"]:
                signs_info = []
                if sign_result["traffic_signs"]:
                    signs_info.append(f"识别到{len(sign_result['traffic_signs'])}个交通标志:")
                    for sign in sign_result["traffic_signs"]:
                        signs_info.append(f"- {sign.get('type', '')}: {sign.get('value', '')}{sign.get('unit', '')} (置信度:{sign.get('confidence', '')}%)")
                if sign_result["traffic_lights"]:
                    signs_info.append(f"识别到{len(sign_result['traffic_lights'])}个交通信号灯:")
                    for light in sign_result["traffic_lights"]:
                        signs_info.append(f"- {light.get('type', '')}: {light.get('status', '')} (置信度:{light.get('confidence', '')}%)")
                
                sign_summary = "\n".join(signs_info) if signs_info else "未识别到交通标志或信号灯"
                
                if content.strip():
                    content = f"{content}\n\n[图片已识别]\n识别结果：\n{sign_summary}"
                else:
                    content = f"识别了一张图片，识别结果：\n{sign_summary}"
            else:
                if content.strip():
                    content = f"{content}\n\n[图片已上传]\n识别失败：{sign_result['error']}"
                else:
                    content = f"识别了一张图片，识别失败：{sign_result['error']}"
                
        except Exception as e:
            if content.strip():
                content = f"{content}\n\n[图片处理失败: {str(e)}]"
            else:
                content = f"识别了一张图片，处理失败：{str(e)}"

    if not content.strip():
        content = "识别了一张图片"

    user_message = ChatSessionService.add_message(db, session.id, "user", content, image_url=image_url)

    messages = ChatSessionService.get_messages_by_session(db, session.id)
    ai_messages = []
    
    for msg in messages:
        ai_messages.append({"role": msg.role, "content": msg.content})

    try:
        ai_response = await ai_service.chat_completion(ai_messages)
    except Exception as e:
        ai_response = f"AI服务暂时不可用，请稍后再试。错误信息：{str(e)}"

    ai_message = ChatSessionService.add_message(db, session.id, "assistant", ai_response)

    result = ChatSessionService.convert_message_to_dict(ai_message)
    
    user_message_dict = ChatSessionService.convert_message_to_dict(user_message)

    return {
        "success": True,
        "data": result,
        "user_images": user_message_dict.get("images", []),
    }