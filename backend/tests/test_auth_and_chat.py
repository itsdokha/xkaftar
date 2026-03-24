import os
from pathlib import Path

os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///./backend-test.db"
os.environ["JWT_SECRET"] = "test-secret"
os.environ["MEDIA_ROOT"] = "backend-test-media"

from httpx import ASGITransport, AsyncClient

from app.main import app


async def test_register_login_and_direct_chat():
    database_path = Path("backend-test.db")
    media_path = Path("backend-test-media")
    if database_path.exists():
        database_path.unlink()
    if media_path.exists():
        for child in media_path.rglob("*"):
            if child.is_file():
                child.unlink()
        for child in sorted(media_path.rglob("*"), reverse=True):
            if child.is_dir():
                child.rmdir()
        media_path.rmdir()

    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://testserver") as client:
            first = await client.post(
                "/auth/register",
                json={"email": "alice@example.com", "password": "strongpass1", "display_name": "Alice"},
            )
            second = await client.post(
                "/auth/register",
                json={"email": "bob@example.com", "password": "strongpass2", "display_name": "Bob"},
            )
            assert first.status_code == 201
            assert second.status_code == 201

            login = await client.post(
                "/auth/login",
                json={"email": "alice@example.com", "password": "strongpass1"},
            )
            assert login.status_code == 200
            access_token = login.json()["tokens"]["access_token"]
            headers = {"Authorization": f"Bearer {access_token}"}

            direct_chat = await client.post("/chats/direct", json={"email": "bob@example.com"}, headers=headers)
            assert direct_chat.status_code == 201
            chat_id = direct_chat.json()["id"]

            message = await client.post(
                f"/chats/{chat_id}/messages",
                json={"body": "Hello, Bob"},
                headers=headers,
            )
            assert message.status_code == 201

            history = await client.get(f"/chats/{chat_id}/messages", headers=headers)
            assert history.status_code == 200
            assert len(history.json()["items"]) == 1
            assert history.json()["items"][0]["body"] == "Hello, Bob"

            avatar = await client.post(
                "/users/me/avatar",
                headers=headers,
                files={"file": ("avatar.png", b"fake-image-data", "image/png")},
            )
            assert avatar.status_code == 200
            assert avatar.json()["avatar_url"].startswith("/media/avatars/")

            photo = await client.post(
                f"/chats/{chat_id}/images",
                headers=headers,
                data={"body": "See this"},
                files={"file": ("photo.png", b"fake-image-data", "image/png")},
            )
            assert photo.status_code == 201
            assert photo.json()["image_url"].startswith("/media/message-images/")
