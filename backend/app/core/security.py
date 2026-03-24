from datetime import datetime, timedelta, timezone
from uuid import uuid4

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.core.settings import get_settings


password_hasher = PasswordHasher()
UTC = timezone.utc


def hash_password(password: str) -> str:
    return password_hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return password_hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False


def create_access_token(user_id: str) -> str:
    settings = get_settings()
    issued_at = datetime.now(UTC)
    expires_at = issued_at + timedelta(minutes=settings.access_token_expire_minutes)
    payload = {
        "sub": user_id,
        "type": "access",
        "exp": expires_at,
        "iat": int(issued_at.timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_refresh_token() -> str:
    return uuid4().hex + uuid4().hex


def decode_token(token: str) -> dict:
    settings = get_settings()
    return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])


def token_issued_at(payload: dict) -> datetime | None:
    issued_at = payload.get("iat")
    if isinstance(issued_at, datetime):
        return issued_at.astimezone(UTC)
    if isinstance(issued_at, (int, float)):
        return datetime.fromtimestamp(issued_at, UTC)
    return None
