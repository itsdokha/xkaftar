import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from app.api.dependencies import DbSession, get_current_user
from app.db.repositories import UserRepository
from app.schemas.admin import AdminSessionRevokeRead
from app.services.realtime import connection_manager


router = APIRouter()
logger = logging.getLogger("app.api.admin")


@router.post("/users/{user_id}/revoke-sessions", response_model=AdminSessionRevokeRead)
async def revoke_user_sessions(
    user_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> AdminSessionRevokeRead:
    if not current_user.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin access required")
    user_repository = UserRepository(session)
    target_user = await user_repository.get_by_id(user_id)
    if target_user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    if target_user.is_system:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="System user cannot be modified")
    target_user = await user_repository.revoke_all_sessions(target_user)
    await session.commit()
    message = "Your session was revoked by an administrator. Please sign in again."
    await connection_manager.send_to_user(
        user_id,
        {
            "event": "session_revoked",
            "data": {
                "message": message,
            },
        },
    )
    await connection_manager.close_user_connections(user_id, reason="session_revoked")
    logger.info(
        "All sessions revoked actor_id=%s target_user_id=%s revoked_at=%s",
        current_user.id,
        user_id,
        target_user.sessions_revoked_at,
    )
    return AdminSessionRevokeRead(user_id=user_id, revoked_at=target_user.sessions_revoked_at)
