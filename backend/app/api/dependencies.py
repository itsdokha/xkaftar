from typing import Annotated

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import decode_token, token_issued_at
from app.db.repositories import UserRepository
from app.db.session import get_db_session


DbSession = Annotated[AsyncSession, Depends(get_db_session)]


async def get_current_user(
    session: DbSession,
    authorization: Annotated[str | None, Header()] = None,
):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1]
    try:
        payload = decode_token(token)
    except Exception as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from error
    if payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")
    user = await UserRepository(session).get_by_id(payload["sub"])
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    issued_at = token_issued_at(payload)
    if user.sessions_revoked_at is not None and (issued_at is None or issued_at <= user.sessions_revoked_at):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Your session was revoked by an administrator. Please sign in again.",
        )
    return user
