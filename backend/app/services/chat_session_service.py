from datetime import datetime
from uuid import uuid4

from sqlalchemy import desc
from sqlalchemy.orm import Session

from app.entity.db_models import ChatSession, ChatMessage


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
    def add_message(db: Session, session_id: int, role: str, content: str, message_type: str = "text") -> ChatMessage:
        session = db.query(ChatSession).filter(ChatSession.id == session_id).first()
        if not session:
            return None

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
            "session_uuid": session.session_uuid,
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