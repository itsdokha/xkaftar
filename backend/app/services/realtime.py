from collections import defaultdict
from datetime import datetime, timezone

from fastapi import WebSocket
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.db.repositories import ChatRepository
from app.db.repositories import UserRepository
from app.db.session import engine
from app.schemas.auth import UserRead


UTC = timezone.utc


class ConnectionManager:
    def __init__(self):
        self.connections: dict[str, set[WebSocket]] = defaultdict(set)
        self.session_factory = async_sessionmaker(engine, expire_on_commit=False)

    async def connect(self, user_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self.session_factory() as session:
            user = await UserRepository(session).set_presence(user_id, True, datetime.now(UTC))
            related_user_ids = await ChatRepository(session).list_related_user_ids(user_id)
            await session.commit()
        self.connections[user_id].add(websocket)
        if user is not None and related_user_ids:
            await self.broadcast_presence(related_user_ids, UserRead.model_validate(user).model_dump(mode="json"))

    async def disconnect(self, user_id: str, websocket: WebSocket) -> None:
        user_connections = self.connections.get(user_id)
        if not user_connections:
            return
        user_connections.discard(websocket)
        if not user_connections:
            self.connections.pop(user_id, None)
            async with self.session_factory() as session:
                user = await UserRepository(session).set_presence(user_id, False, datetime.now(UTC))
                related_user_ids = await ChatRepository(session).list_related_user_ids(user_id)
                await session.commit()
            if user is not None and related_user_ids:
                await self.broadcast_presence(related_user_ids, UserRead.model_validate(user).model_dump(mode="json"))

    async def send_to_user(self, user_id: str, payload: dict) -> None:
        for websocket in list(self.connections.get(user_id, set())):
            await websocket.send_json(payload)

    async def close_user_connections(self, user_id: str, code: int = 4401, reason: str | None = None) -> None:
        for websocket in list(self.connections.get(user_id, set())):
            try:
                await websocket.close(code=code, reason=reason)
            except Exception:
                pass

    async def broadcast(self, user_ids: list[str], payload: dict) -> None:
        for user_id in user_ids:
            await self.send_to_user(user_id, payload)

    async def broadcast_presence(self, user_ids: list[str], user_payload: dict) -> None:
        payload = {"event": "presence_updated", "data": user_payload}
        await self.broadcast(user_ids, payload)

    async def handle_typing(self, user_id: str, chat_id: str, is_typing: bool) -> None:
        async with self.session_factory() as session:
            chat_repository = ChatRepository(session)
            membership = await chat_repository.get_member(chat_id, user_id)
            if membership is None:
                return
            member_user_ids = await chat_repository.list_member_user_ids(chat_id)
        recipients = [member_user_id for member_user_id in member_user_ids if member_user_id != user_id]
        if not recipients:
            return
        await self.broadcast(
            recipients,
            {
                "event": "typing_updated",
                "data": {
                    "chat_id": chat_id,
                    "user_id": user_id,
                    "is_typing": is_typing,
                },
            },
        )


connection_manager = ConnectionManager()
