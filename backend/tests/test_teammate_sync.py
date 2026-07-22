from datetime import timezone

from fastapi.middleware.cors import CORSMiddleware

from app.core import security
from app.services import scheduler_service as scheduler_module
from main import app


def test_chat_sessions_use_the_api_namespace(client):
    client.post(
        "/api/auth/register",
        json={
            "username": "chat_route_user",
            "email": "chat-route@example.com",
            "password": "123456",
        },
    )
    login = client.post(
        "/api/auth/login",
        json={"username": "chat_route_user", "password": "123456"},
    )
    headers = {
        "Authorization": f"Bearer {login.json()['access_token']}"
    }

    response = client.post(
        "/api/chat-sessions",
        params={"title": "Route check"},
        headers=headers,
    )

    assert response.status_code == 200


def test_cors_middleware_is_registered_once():
    cors_entries = [
        middleware
        for middleware in app.user_middleware
        if middleware.cls is CORSMiddleware
    ]

    assert len(cors_entries) == 1


def test_access_token_expiration_is_utc_aware(monkeypatch):
    captured = {}

    def fake_encode(payload, *_args, **_kwargs):
        captured.update(payload)
        return "token"

    monkeypatch.setattr(security.jwt, "encode", fake_encode)

    assert security.create_access_token({"sub": "1"}) == "token"
    assert captured["exp"].tzinfo is timezone.utc


def test_scheduler_closes_database_dependency(monkeypatch):
    database = object()

    class DatabaseDependency:
        def __init__(self):
            self.closed = False

        def __iter__(self):
            return self

        def __next__(self):
            return database

        def close(self):
            self.closed = True

    dependency = DatabaseDependency()
    monkeypatch.setattr(scheduler_module, "get_db", lambda: dependency)
    monkeypatch.setattr(
        scheduler_module.file_cache_service,
        "clear_all",
        lambda db: 1 if db is database else 0,
    )

    scheduler_module.scheduler_service._clear_file_cache_daily()

    assert dependency.closed is True
