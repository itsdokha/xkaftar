from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.domain.enums import ChatRole, ChatType, MessageKind
from app.schemas.auth import UserRead


class MessageCreate(BaseModel):
    body: str = Field(default="", max_length=4000)
    reply_to_message_id: str | None = None
    client_message_id: str | None = Field(default=None, max_length=128)


class MessageReplyRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    sender: UserRead
    body: str
    image_url: str | None = None
    video_url: str | None = None
    created_at: datetime
    kind: MessageKind = MessageKind.USER


class ReactionRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    emoji: str
    user: UserRead
    created_at: datetime


class MessageRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    chat_id: str
    sender: UserRead
    body: str
    image_url: str | None = None
    video_url: str | None = None
    created_at: datetime
    kind: MessageKind = MessageKind.USER
    reply_to: MessageReplyRead | None = None
    reactions: list[ReactionRead] = []


class MessagePageRead(BaseModel):
    items: list[MessageRead]
    total: int
    has_more: bool
    next_before_message_id: str | None = None


class ChatMemberRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    role: ChatRole
    joined_at: datetime
    last_read_at: datetime | None = None
    user: UserRead


class ChatRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    type: ChatType
    title: str | None
    icon_url: str | None
    created_by_id: str
    created_at: datetime
    updated_at: datetime
    members: list[ChatMemberRead]
    last_message: MessageRead | None = None
    unread_count: int = 0
    notifications_enabled: bool = True


class VoiceParticipantRead(BaseModel):
    user: UserRead
    joined_at: datetime
    is_muted: bool = False


class VoiceStateRead(BaseModel):
    chat_id: str
    room_name: str
    room_active: bool
    participants: list[VoiceParticipantRead]
    updated_at: datetime


class VoiceJoinRead(BaseModel):
    chat_id: str
    room_name: str
    server_url: str
    participant_token: str
    participant_identity: str
    state: VoiceStateRead


class DirectChatCreate(BaseModel):
    email: EmailStr


class GroupChatCreate(BaseModel):
    title: str = Field(min_length=2, max_length=255)
    member_emails: list[EmailStr] = Field(default_factory=list)


class AddMemberRequest(BaseModel):
    email: EmailStr


class ChatNotificationSettingsUpdate(BaseModel):
    enabled: bool


class GroupChatRenameRequest(BaseModel):
    title: str = Field(min_length=2, max_length=255)
