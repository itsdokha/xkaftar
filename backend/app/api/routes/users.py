import logging
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status

from app.api.dependencies import DbSession, get_current_user
from app.db.repositories import UserRepository
from app.schemas.auth import UpdateProfileRequest, UserRead
from app.services.exceptions import ConflictError
from app.services.storage import StorageService


router = APIRouter()
logger = logging.getLogger("app.api.users")


@router.get("/me", response_model=UserRead)
async def get_me(current_user: Annotated[object, Depends(get_current_user)]) -> UserRead:
    logger.info("Current user requested user_id=%s", current_user.id)
    return UserRead.model_validate(current_user)


async def _update_me_impl(
    payload: UpdateProfileRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> UserRead:
    next_display_name = (payload.display_name or current_user.display_name).strip()
    if len(next_display_name) < 2:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Display name is too short")
    user = await UserRepository(session).update_profile(
        current_user,
        display_name=next_display_name,
        bio=payload.bio,
    )
    await session.commit()
    logger.info(
        "Profile updated user_id=%s display_name=%s bio_length=%s",
        current_user.id,
        next_display_name,
        len(payload.bio.strip()),
    )
    return UserRead.model_validate(user)


@router.patch("/me", response_model=UserRead)
async def update_me_patch(
    payload: UpdateProfileRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> UserRead:
    return await _update_me_impl(payload, session, current_user)


@router.post("/me", response_model=UserRead)
async def update_me_post(
    payload: UpdateProfileRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> UserRead:
    return await _update_me_impl(payload, session, current_user)


@router.get("", response_model=list[UserRead])
async def list_users(
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> list[UserRead]:
    users = await UserRepository(session).list_all(exclude_user_id=current_user.id)
    logger.info("Users listed actor_id=%s count=%s", current_user.id, len(users))
    return [UserRead.model_validate(user) for user in users]


@router.post("/me/avatar", response_model=UserRead)
async def upload_avatar(
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    file: UploadFile = File(...),
) -> UserRead:
    try:
        avatar_url = await StorageService().save_avatar(file, current_user.id)
    except ConflictError as error:
        logger.warning("Avatar upload conflict user_id=%s filename=%s detail=%s", current_user.id, file.filename, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    user = await UserRepository(session).update_avatar(current_user, avatar_url)
    await session.commit()
    logger.info("Avatar uploaded user_id=%s filename=%s", current_user.id, file.filename)
    return UserRead.model_validate(user)
