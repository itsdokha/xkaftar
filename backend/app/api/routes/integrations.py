import logging

from fastapi import APIRouter, HTTPException, Request, status
from livekit import api as livekit_api
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.core.settings import get_settings
from app.db.session import engine
from app.services.realtime import connection_manager
from app.services.voice import VoiceService


router = APIRouter()
logger = logging.getLogger("app.api.integrations")
settings = get_settings()
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)


@router.post("/livekit/webhook")
async def livekit_webhook(request: Request) -> dict[str, bool]:
    if not settings.voice_enabled:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Voice chat is not configured")
    authorization = request.headers.get("Authorization", "")
    body = await request.body()
    try:
        receiver = livekit_api.WebhookReceiver(
            livekit_api.TokenVerifier(
                api_key=settings.livekit_webhook_key or settings.livekit_api_key,
                api_secret=settings.livekit_api_secret,
            )
        )
        event = receiver.receive(body.decode("utf-8"), authorization)
    except Exception as error:
        logger.warning("LiveKit webhook rejected detail=%s", error)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid webhook") from error
    room = getattr(event, "room", None)
    room_name = getattr(room, "name", "")
    async with SessionFactory() as session:
        service = VoiceService(session)
        chat_id = service.chat_id_from_room_name(room_name)
        if not chat_id:
            logger.info("LiveKit webhook ignored event=%s room_name=%s", getattr(event, "event", None), room_name)
            return {"ok": True}
        state = await service.get_state_for_chat(chat_id)
        user_ids = await service.voice_member_user_ids(chat_id)
    await connection_manager.broadcast(
        user_ids,
        {"event": "voice_state_updated", "data": state.model_dump(mode="json")},
    )
    logger.info(
        "LiveKit webhook handled event=%s chat_id=%s participants=%s",
        getattr(event, "event", None),
        chat_id,
        len(state.participants),
    )
    return {"ok": True}
