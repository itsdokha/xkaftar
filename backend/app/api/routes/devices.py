import logging
from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.dependencies import DbSession, get_current_user
from app.db.repositories import PushDeviceTokenRepository
from app.schemas.devices import (
    PushDeviceTokenRead,
    PushDeviceTokenRegisterRequest,
    PushDeviceTokenUnregisterRequest,
)


router = APIRouter()
logger = logging.getLogger("app.api.devices")


@router.post("/push/register", response_model=PushDeviceTokenRead)
async def register_push_token(
    payload: PushDeviceTokenRegisterRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> PushDeviceTokenRead:
    device_token = await PushDeviceTokenRepository(session).upsert(
        user_id=current_user.id,
        token=payload.token,
        platform=payload.platform.strip().lower(),
    )
    await session.commit()
    logger.info(
        "Push token registered user_id=%s platform=%s token_prefix=%s",
        current_user.id,
        device_token.platform,
        device_token.token[:12],
    )
    return PushDeviceTokenRead.model_validate(device_token)


@router.post("/push/unregister")
async def unregister_push_token(
    payload: PushDeviceTokenUnregisterRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> dict[str, bool]:
    removed = await PushDeviceTokenRepository(session).delete(current_user.id, payload.token)
    await session.commit()
    logger.info(
        "Push token unregistered user_id=%s removed=%s token_prefix=%s",
        current_user.id,
        removed,
        payload.token[:12],
    )
    return {"removed": removed}
