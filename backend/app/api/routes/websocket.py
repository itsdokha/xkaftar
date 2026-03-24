import json
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from jwt import ExpiredSignatureError, InvalidTokenError
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.core.security import decode_token, token_issued_at
from app.db.repositories import UserRepository
from app.db.session import engine
from app.services.realtime import connection_manager


router = APIRouter()
logger = logging.getLogger("app.api.websocket")
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    token = websocket.query_params.get("token")
    if not token:
        logger.warning("WebSocket rejected because token is missing client=%s", websocket.client)
        await websocket.close(code=4401)
        return
    try:
        payload = decode_token(token)
        if payload.get("type") != "access":
            raise ValueError("Invalid token type")
        user_id = payload["sub"]
    except ExpiredSignatureError:
        logger.info("WebSocket rejected because token expired client=%s", websocket.client)
        await websocket.close(code=4401)
        return
    except (InvalidTokenError, ValueError, KeyError) as error:
        logger.warning("WebSocket rejected because token is invalid client=%s detail=%s", websocket.client, error)
        await websocket.close(code=4401)
        return
    async with SessionFactory() as session:
        user = await UserRepository(session).get_by_id(user_id)
    issued_at = token_issued_at(payload)
    if user is None or (user.sessions_revoked_at is not None and (issued_at is None or issued_at <= user.sessions_revoked_at)):
        logger.warning("WebSocket rejected because session is revoked user_id=%s client=%s", user_id, websocket.client)
        await websocket.close(code=4401, reason="session_revoked")
        return
    logger.info("WebSocket authenticated user_id=%s client=%s", user_id, websocket.client)
    await connection_manager.connect(user_id, websocket)
    try:
        while True:
            payload = await websocket.receive_text()
            try:
                message = json.loads(payload)
            except json.JSONDecodeError:
                logger.warning("WebSocket payload is not valid JSON user_id=%s", user_id)
                continue
            if not isinstance(message, dict):
                logger.warning("WebSocket payload is not an object user_id=%s", user_id)
                continue
            if message.get("type") == "typing":
                chat_id = message.get("chat_id")
                is_typing = bool(message.get("is_typing"))
                if isinstance(chat_id, str) and chat_id:
                    logger.info("Typing event user_id=%s chat_id=%s is_typing=%s", user_id, chat_id, is_typing)
                    await connection_manager.handle_typing(user_id, chat_id, is_typing)
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected user_id=%s", user_id)
    except Exception:
        logger.exception("WebSocket crashed user_id=%s", user_id)
        raise
    finally:
        await connection_manager.disconnect(user_id, websocket)
