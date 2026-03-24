from app.db.models import Chat, Message
from app.schemas.chat import ChatRead, MessageRead, MessageReplyRead


def message_reply_to_schema(message: Message) -> MessageReplyRead:
    return MessageReplyRead.model_validate(
        {
            "id": message.id,
            "sender": message.sender,
            "body": message.body,
            "image_url": message.image_url,
            "created_at": message.created_at,
            "kind": message.kind,
        }
    )


def message_to_schema(message: Message) -> MessageRead:
    reactions = []
    if hasattr(message, "reactions") and message.reactions:
        reactions = [{"emoji": r.emoji, "user": r.user, "created_at": r.created_at} for r in message.reactions]
    return MessageRead.model_validate(
        {
            "id": message.id,
            "chat_id": message.chat_id,
            "sender": message.sender,
            "body": message.body,
            "image_url": message.image_url,
            "created_at": message.created_at,
            "kind": message.kind,
            "reply_to": message_reply_to_schema(message.reply_to) if message.reply_to is not None else None,
            "reactions": reactions,
        }
    )


def chat_to_schema(
    chat: Chat,
    last_message: Message | None = None,
    unread_count: int = 0,
    notifications_enabled: bool = True,
) -> ChatRead:
    payload = ChatRead.model_validate(chat)
    if last_message is not None:
        payload.last_message = message_to_schema(last_message)
    payload.unread_count = unread_count
    payload.notifications_enabled = notifications_enabled
    return payload
