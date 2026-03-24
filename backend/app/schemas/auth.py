from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=2, max_length=255)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class UpdateProfileRequest(BaseModel):
    display_name: str | None = Field(default=None, min_length=2, max_length=255)
    bio: str = Field(default="", max_length=500)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=32)


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    email: EmailStr
    display_name: str
    avatar_url: str | None = None
    bio: str | None = None
    is_system: bool = False
    is_admin: bool = False
    is_online: bool = False
    last_seen_at: datetime | None = None


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class AuthResponse(BaseModel):
    user: UserRead
    tokens: TokenPair
