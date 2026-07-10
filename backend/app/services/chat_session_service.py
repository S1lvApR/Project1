from datetime import datetime
from uuid import uuid4

from sqlalchemy import desc
from sqlalchemy.orm import Session

from app.entity.db_models import ChatSession, ChatMessage
from app.services.user_service import user_service


class ChatSessionService:
    @staticmethod
    def create_session(db: Session, user_id: int, title: str = "New Chat") -> ChatSession:
        session = ChatSession(
            user_id=user_id,
            session_uuid=str(uuid4()),
            title=title,
        )
        db.add(session)
        db.commit()
        db.refresh(session)
        return session

    @staticmethod
    def get_session_by_uuid(db: Session, session_uuid: str) -> ChatSession:
        return db.query(ChatSession).filter(ChatSession.session_uuid == session_uuid).first()

    @staticmethod
    def get_sessions_by_user(db: Session, user_id: int) -> list[ChatSession]:
        return (
            db.query(ChatSession)
            .filter(ChatSession.user_id == user_id, ChatSession.status == "active")
            .order_by(desc(ChatSession.created_at))
            .all()
        )

    @staticmethod
    def update_session_title(db: Session, session_id: int, title: str) -> ChatSession:
        session = db.query(ChatSession).filter(ChatSession.id == session_id).first()
        if session:
            session.title = title
            db.commit()
            db.refresh(session)
        return session

    @staticmethod
    def add_message(db: Session, session_id: int, role: str, content: str, message_type: str = "text", user=None) -> ChatMessage:
        session = db.query(ChatSession).filter(ChatSession.id == session_id).first()
        if not session:
            return None

        if role == "user" and user and content.startswith("/"):
            if not user_service.is_admin(db, user):
                message = ChatMessage(
                    session_id=session_id,
                    role="assistant",
                    content="无权执行管理员命令",
                )
                db.add(message)
                session.message_count = db.query(ChatMessage).filter(ChatMessage.session_id == session_id).count()
                session.last_message_at = datetime.now()
                db.commit()
                db.refresh(message)
                return message

            response_content = ChatSessionService._handle_admin_command(db, content.strip())

            message = ChatMessage(
                session_id=session_id,
                role="assistant",
                content=response_content,
            )
            db.add(message)
            session.message_count = db.query(ChatMessage).filter(ChatMessage.session_id == session_id).count()
            session.last_message_at = datetime.now()
            db.commit()
            db.refresh(message)
            return message

        message = ChatMessage(
            session_id=session_id,
            role=role,
            content=content,
        )
        db.add(message)
        
        session.message_count = db.query(ChatMessage).filter(ChatMessage.session_id == session_id).count()
        session.last_message_at = datetime.now()
        
        if session.message_count > 20:
            oldest_messages = (
                db.query(ChatMessage)
                .filter(ChatMessage.session_id == session_id)
                .order_by(ChatMessage.created_at)
                .limit(session.message_count - 20)
                .all()
            )
            for msg in oldest_messages:
                db.delete(msg)
        
        db.commit()
        db.refresh(message)
        return message

    @staticmethod
    def _handle_admin_command(db, command):
        user_service.seed_admin_permissions(db)
        
        if command == "/command":
            permissions = user_service.get_permissions(db)
            if not permissions:
                return "权限表为空"
            result = "可用管理员命令：\n"
            for perm in permissions:
                result += f"• {perm['code']} - {perm['name']}\n  {perm['description']}\n\n"
            return result.strip()
        
        permissions = user_service.get_permissions(db)
        matched_perm = None
        for perm in permissions:
            if command.startswith(perm["code"] + "+"):
                matched_perm = perm
                break
        
        if matched_perm:
            cmd_code = matched_perm["code"]
            if cmd_code == "/gp":
                username = command[4:].strip()
                if not username:
                    return f"请指定要授予权限的账号，格式：{cmd_code}+账号"
                success = user_service.grant_admin(db, username)
                return f"已成功授予账号 '{username}' 管理员权限" if success else f"账号 '{username}' 不存在或已是管理员"
            
            if cmd_code == "/rp":
                username = command[4:].strip()
                if not username:
                    return f"请指定要收回权限的账号，格式：{cmd_code}+账号"
                success = user_service.revoke_admin(db, username)
                if not success:
                    if username == "111":
                        return "账号 '111' 的管理员权限不可被收回"
                    return f"账号 '{username}' 不存在或不是管理员"
                return f"已成功收回账号 '{username}' 的管理员权限"
            
            if cmd_code == "/delete":
                username = command[8:].strip()
                if not username:
                    return f"请指定要删除的账号，格式：{cmd_code}+账号"
                success = user_service.delete_user(db, username)
                if not success:
                    if username == "111":
                        return "账号 '111' 不可被删除"
                    return f"账号 '{username}' 不存在"
                return f"已成功删除账号 '{username}' 及其所有相关信息"
        
        return "未知命令"

    @staticmethod
    def get_messages_by_session(db: Session, session_id: int, limit: int = 20) -> list[ChatMessage]:
        return (
            db.query(ChatMessage)
            .filter(ChatMessage.session_id == session_id)
            .order_by(desc(ChatMessage.created_at))
            .limit(limit)
            .all()[::-1]
        )

    @staticmethod
    def delete_session(db: Session, session_id: int) -> bool:
        session = db.query(ChatSession).filter(ChatSession.id == session_id).first()
        if session:
            db.delete(session)
            db.commit()
            return True
        return False

    @staticmethod
    def convert_session_to_dict(session: ChatSession) -> dict:
        messages = []
        if session.messages:
            for msg in session.messages:
                messages.append({
                    "id": str(msg.id),
                    "conversationId": session.session_uuid,
                    "role": msg.role,
                    "content": msg.content,
                    "createdAt": msg.created_at.isoformat() if msg.created_at else None,
                    "type": "text",
                })
        
        return {
            "id": session.session_uuid,
            "title": session.title,
            "messages": messages,
            "createdAt": session.created_at.isoformat() if session.created_at else None,
            "updatedAt": session.updated_at.isoformat() if session.updated_at else None,
        }

    @staticmethod
    def convert_message_to_dict(message: ChatMessage) -> dict:
        return {
            "id": str(message.id),
            "conversationId": message.session.session_uuid,
            "role": message.role,
            "content": message.content,
            "createdAt": message.created_at.isoformat() if message.created_at else None,
            "type": "text",
        }