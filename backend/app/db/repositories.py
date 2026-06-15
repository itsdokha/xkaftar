from collections.abc import Sequence
from datetime import datetime, timezone

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.settings import get_settings
from app.db.models import Chat, ChatMember, Message, MessageReaction, PushDeviceToken, RefreshToken, User
from app.domain.enums import ChatRole, ChatType, MessageKind


UTC = timezone.utc


class UserRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def create(self, email: str, password_hash: str, display_name: str) -> User:
        user = User(email=email, password_hash=password_hash, display_name=display_name)
        self.session.add(user)
        await self.session.flush()
        return user

    async def get_by_email(self, email: str) -> User | None:
        result = await self.session.execute(select(User).where(func.lower(User.email) == email.lower()))
        return result.scalar_one_or_none()

    async def get_by_id(self, user_id: str) -> User | None:
        result = await self.session.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()

    async def list_all_ids(self) -> list[str]:
        result = await self.session.execute(select(User.id))
        return result.scalars().all()

    async def list_all(self, exclude_user_id: str | None = None, *, include_system: bool = False) -> Sequence[User]:
        query = select(User)
        if exclude_user_id is not None:
            query = query.where(User.id != exclude_user_id)
        if not include_system:
            system_email = get_settings().system_user_email.lower()
            query = query.where(func.lower(User.email) != system_email)
        result = await self.session.execute(query.order_by(func.lower(User.display_name), func.lower(User.email)))
        return result.scalars().all()

    async def is_admin(self, user_id: str) -> bool:
        result = await self.session.execute(select(User.email).where(User.id == user_id))
        email = result.scalar_one_or_none()
        if email is None:
            return False
        return email.lower() == get_settings().admin_user_email.lower()

    async def get_by_ids(self, user_ids: Sequence[str]) -> dict[str, User]:
        if not user_ids:
            return {}
        result = await self.session.execute(select(User).where(User.id.in_(user_ids)))
        users = result.scalars().all()
        return {user.id: user for user in users}

    async def update_avatar(self, user: User, avatar_url: str) -> User:
        user.avatar_url = avatar_url
        await self.session.flush()
        return user

    async def update_profile(self, user: User, *, display_name: str, bio: str) -> User:
        user.display_name = display_name.strip()
        user.bio = bio.strip() or None
        await self.session.flush()
        return user

    async def revoke_all_sessions(self, user: User, revoked_at: datetime | None = None) -> User:
        user.sessions_revoked_at = revoked_at or datetime.now(UTC)
        await self.session.flush()
        return user

    async def set_presence(self, user_id: str, is_online: bool, last_seen_at: datetime | None) -> User | None:
        user = await self.get_by_id(user_id)
        if user is None:
            return None
        user.is_online = is_online
        user.last_seen_at = last_seen_at
        await self.session.flush()
        return user


class TokenRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def create(self, user_id: str, token: str, expires_at: datetime) -> RefreshToken:
        refresh_token = RefreshToken(user_id=user_id, token=token, expires_at=expires_at)
        self.session.add(refresh_token)
        await self.session.flush()
        return refresh_token

    async def get_valid(self, token: str) -> RefreshToken | None:
        now = datetime.now(UTC)
        result = await self.session.execute(
            select(RefreshToken).where(and_(RefreshToken.token == token, RefreshToken.expires_at > now))
        )
        return result.scalar_one_or_none()


class PushDeviceTokenRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def upsert(self, user_id: str, token: str, platform: str) -> PushDeviceToken:
        result = await self.session.execute(select(PushDeviceToken).where(PushDeviceToken.token == token))
        existing = result.scalar_one_or_none()
        if existing is None:
            device_token = PushDeviceToken(user_id=user_id, token=token, platform=platform)
            self.session.add(device_token)
            await self.session.flush()
            return device_token
        existing.user_id = user_id
        existing.platform = platform
        await self.session.flush()
        return existing

    async def delete(self, user_id: str, token: str) -> bool:
        result = await self.session.execute(
            select(PushDeviceToken).where(
                and_(PushDeviceToken.user_id == user_id, PushDeviceToken.token == token)
            )
        )
        existing = result.scalar_one_or_none()
        if existing is None:
            return False
        await self.session.delete(existing)
        await self.session.flush()
        return True

    async def delete_many_by_tokens(self, tokens: Sequence[str]) -> int:
        if not tokens:
            return 0
        result = await self.session.execute(
            select(PushDeviceToken).where(PushDeviceToken.token.in_(list(tokens)))
        )
        existing = result.scalars().all()
        for item in existing:
            await self.session.delete(item)
        await self.session.flush()
        return len(existing)

    async def list_for_user_ids(self, user_ids: Sequence[str]) -> list[PushDeviceToken]:
        if not user_ids:
            return []
        result = await self.session.execute(
            select(PushDeviceToken)
            .where(PushDeviceToken.user_id.in_(user_ids))
            .order_by(PushDeviceToken.updated_at.desc())
        )
        return result.scalars().all()


class ChatRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_by_id(self, chat_id: str) -> Chat | None:
        result = await self.session.execute(
            select(Chat)
            .where(Chat.id == chat_id)
            .options(
                selectinload(Chat.members).selectinload(ChatMember.user),
            )
        )
        return result.scalar_one_or_none()

    async def list_for_user(self, user_id: str) -> Sequence[Chat]:
        result = await self.session.execute(
            select(Chat)
            .join(ChatMember, ChatMember.chat_id == Chat.id)
            .where(ChatMember.user_id == user_id)
            .options(
                selectinload(Chat.members).selectinload(ChatMember.user),
            )
            .order_by(Chat.updated_at.desc())
        )
        return result.scalars().unique().all()

    async def list_all_chats(self) -> Sequence[Chat]:
        result = await self.session.execute(
            select(Chat)
            .options(
                selectinload(Chat.members).selectinload(ChatMember.user),
            )
            .order_by(Chat.updated_at.desc())
        )
        return result.scalars().unique().all()

    async def list_related_user_ids(self, user_id: str) -> list[str]:
        result = await self.session.execute(
            select(ChatMember.user_id)
            .join(Chat, Chat.id == ChatMember.chat_id)
            .where(
                Chat.id.in_(
                    select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
                )
            )
        )
        return list(dict.fromkeys(result.scalars().all()))

    async def list_member_user_ids(self, chat_id: str) -> list[str]:
        result = await self.session.execute(
            select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
        )
        return result.scalars().all()

    async def list_group_ids_by_title(self, title: str) -> list[str]:
        result = await self.session.execute(
            select(Chat.id).where(
                and_(
                    Chat.type == ChatType.GROUP,
                    func.lower(Chat.title) == title.lower(),
                )
            )
        )
        return result.scalars().all()

    async def find_direct_between(self, first_user_id: str, second_user_id: str) -> Chat | None:
        subquery = (
            select(Chat.id)
            .join(ChatMember, ChatMember.chat_id == Chat.id)
            .where(Chat.type == ChatType.DIRECT, ChatMember.user_id.in_([first_user_id, second_user_id]))
            .group_by(Chat.id)
            .having(func.count(ChatMember.user_id.distinct()) == 2)
            .subquery()
        )
        result = await self.session.execute(
            select(Chat)
            .where(Chat.id.in_(select(subquery.c.id)))
            .options(
                selectinload(Chat.members).selectinload(ChatMember.user),
            )
        )
        return result.scalar_one_or_none()

    async def create_chat(self, chat_type: ChatType, created_by_id: str, title: str | None = None) -> Chat:
        chat = Chat(type=chat_type, created_by_id=created_by_id, title=title)
        self.session.add(chat)
        await self.session.flush()
        return chat

    async def update_icon(self, chat: Chat, icon_url: str) -> Chat:
        chat.icon_url = icon_url
        await self.session.flush()
        return chat

    async def rename(self, chat: Chat, title: str) -> Chat:
        chat.title = title
        await self.session.flush()
        return chat

    async def add_member(self, chat_id: str, user_id: str, role: ChatRole) -> ChatMember:
        member = ChatMember(
            chat_id=chat_id,
            user_id=user_id,
            role=role,
            last_read_at=datetime.now(UTC),
            notifications_enabled=True,
        )
        self.session.add(member)
        await self.session.flush()
        return member

    async def get_member(self, chat_id: str, user_id: str) -> ChatMember | None:
        result = await self.session.execute(
            select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id))
        )
        return result.scalar_one_or_none()

    async def touch(self, chat: Chat) -> Chat:
        chat.updated_at = datetime.now(UTC)
        await self.session.flush()
        return chat

    async def mark_read(self, chat_id: str, user_id: str, read_at: datetime | None = None) -> ChatMember | None:
        member = await self.get_member(chat_id, user_id)
        if member is None:
            return None
        target_read_at = read_at or datetime.now(UTC)
        if member.last_read_at is not None and member.last_read_at >= target_read_at:
            return member
        member.last_read_at = target_read_at
        await self.session.flush()
        return member

    async def set_notifications_enabled(self, chat_id: str, user_id: str, enabled: bool) -> ChatMember | None:
        member = await self.get_member(chat_id, user_id)
        if member is None:
            return None
        member.notifications_enabled = enabled
        await self.session.flush()
        return member

    async def remove_member(self, member: ChatMember) -> None:
        await self.session.delete(member)
        await self.session.flush()

    async def delete_chat(self, chat: Chat) -> None:
        await self.session.delete(chat)
        await self.session.flush()

    async def list_notifiable_user_ids(self, chat_id: str, exclude_user_id: str | None = None) -> list[str]:
        query = select(ChatMember.user_id).where(
            and_(
                ChatMember.chat_id == chat_id,
                ChatMember.notifications_enabled.is_(True),
            )
        )
        if exclude_user_id is not None:
            query = query.where(ChatMember.user_id != exclude_user_id)
        result = await self.session.execute(query)
        return result.scalars().all()

    async def get_unread_counts(self, chat_ids: Sequence[str], user_id: str) -> dict[str, int]:
        if not chat_ids:
            return {}
        result = await self.session.execute(
            select(ChatMember.chat_id, func.count(Message.id))
            .select_from(ChatMember)
            .outerjoin(
                Message,
                and_(
                    Message.chat_id == ChatMember.chat_id,
                    Message.deleted_at.is_(None),
                    Message.sender_id != user_id,
                    or_(ChatMember.last_read_at.is_(None), Message.created_at > ChatMember.last_read_at),
                ),
            )
            .where(and_(ChatMember.user_id == user_id, ChatMember.chat_id.in_(chat_ids)))
            .group_by(ChatMember.chat_id)
        )
        return {chat_id: unread_count for chat_id, unread_count in result.all()}


class MessageRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def create(
        self,
        chat_id: str,
        sender_id: str,
        body: str,
        image_url: str | None = None,
        video_url: str | None = None,
        reply_to_message_id: str | None = None,
        kind: MessageKind = MessageKind.USER,
        client_message_id: str | None = None,
    ) -> Message:
        message = Message(
            chat_id=chat_id,
            sender_id=sender_id,
            client_message_id=client_message_id,
            kind=kind,
            body=body,
            image_url=image_url,
            video_url=video_url,
            reply_to_message_id=reply_to_message_id,
        )
        self.session.add(message)
        await self.session.flush()
        return message

    async def get_by_client_message_id(
        self,
        chat_id: str,
        sender_id: str,
        client_message_id: str,
    ) -> Message | None:
        result = await self.session.execute(
            select(Message)
            .where(
                and_(
                    Message.chat_id == chat_id,
                    Message.sender_id == sender_id,
                    Message.client_message_id == client_message_id,
                    Message.deleted_at.is_(None),
                )
            )
            .options(
                selectinload(Message.sender),
                selectinload(Message.reply_to).selectinload(Message.sender),
                selectinload(Message.reactions).selectinload(MessageReaction.user),
            )
        )
        return result.scalar_one_or_none()

    async def get_by_id(self, message_id: str, *, populate_existing: bool = False) -> Message | None:
        result = await self.session.execute(
            select(Message)
            .where(Message.id == message_id)
            .execution_options(populate_existing=populate_existing)
            .options(
                selectinload(Message.sender),
                selectinload(Message.reply_to).selectinload(Message.sender),
                selectinload(Message.reactions).selectinload(MessageReaction.user),
            )
        )
        return result.scalar_one_or_none()

    async def count_for_chat(self, chat_id: str) -> int:
        result = await self.session.execute(
            select(func.count(Message.id)).where(and_(Message.chat_id == chat_id, Message.deleted_at.is_(None)))
        )
        return result.scalar_one()

    async def list_for_chat(
        self,
        chat_id: str,
        limit: int = 50,
        before_message_id: str | None = None,
    ) -> Sequence[Message]:
        query = (
            select(Message)
            .where(and_(Message.chat_id == chat_id, Message.deleted_at.is_(None)))
            .options(
                selectinload(Message.sender),
                selectinload(Message.reply_to).selectinload(Message.sender),
                selectinload(Message.reactions).selectinload(MessageReaction.user),
            )
        )
        if before_message_id is not None:
            cursor_message = await self.get_by_id(before_message_id)
            if cursor_message is None or cursor_message.chat_id != chat_id:
                return []
            query = query.where(
                or_(
                    Message.created_at < cursor_message.created_at,
                    and_(Message.created_at == cursor_message.created_at, Message.id < cursor_message.id),
                )
            )
        result = await self.session.execute(
            query
            .order_by(Message.created_at.desc(), Message.id.desc())
            .limit(limit)
        )
        messages = result.scalars().unique().all()
        return list(reversed(messages))

    async def get_latest_for_chats(self, chat_ids: Sequence[str]) -> dict[str, Message]:
        if not chat_ids:
            return {}
        ranked_messages = (
            select(
                Message.id.label("message_id"),
                func.row_number()
                .over(partition_by=Message.chat_id, order_by=(Message.created_at.desc(), Message.id.desc()))
                .label("position"),
            )
            .where(and_(Message.chat_id.in_(chat_ids), Message.deleted_at.is_(None)))
            .subquery()
        )
        result = await self.session.execute(
            select(Message)
            .join(ranked_messages, ranked_messages.c.message_id == Message.id)
            .where(ranked_messages.c.position == 1)
            .options(
                selectinload(Message.sender),
                selectinload(Message.reply_to).selectinload(Message.sender),
                selectinload(Message.reactions).selectinload(MessageReaction.user),
            )
        )
        messages = result.scalars().unique().all()
        return {message.chat_id: message for message in messages}

    async def add_reaction(self, message_id: str, user_id: str, emoji: str) -> MessageReaction:
        existing = await self.session.execute(
            select(MessageReaction)
            .where(
                and_(
                    MessageReaction.message_id == message_id,
                    MessageReaction.user_id == user_id,
                )
            )
            .order_by(MessageReaction.created_at.desc(), MessageReaction.id.desc())
        )
        existing_reactions = existing.scalars().all()
        same_emoji: MessageReaction | None = None
        for reaction in existing_reactions:
            if reaction.emoji == emoji and same_emoji is None:
                same_emoji = reaction
                continue
            if reaction.emoji != emoji or same_emoji is not None:
                await self.session.delete(reaction)
        await self.session.flush()
        if same_emoji is not None:
            return same_emoji
        reaction = MessageReaction(message_id=message_id, user_id=user_id, emoji=emoji)
        self.session.add(reaction)
        await self.session.flush()
        return reaction

    async def remove_reaction(self, message_id: str, user_id: str, emoji: str) -> bool:
        result = await self.session.execute(
            select(MessageReaction).where(
                and_(
                    MessageReaction.message_id == message_id,
                    MessageReaction.user_id == user_id,
                    MessageReaction.emoji == emoji,
                )
            )
        )
        reaction = result.scalar_one_or_none()
        if reaction is None:
            return False
        await self.session.delete(reaction)
        await self.session.flush()
        return True
