import logging
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import create_access_token, create_refresh_token, hash_password, verify_password
from app.core.settings import get_settings
from app.db.repositories import ChatRepository, MessageRepository, TokenRepository, UserRepository
from app.domain.enums import ChatRole, ChatType
from app.schemas.auth import AuthResponse, TokenPair, UserRead
from app.services.exceptions import AuthenticationError, ConflictError
from app.services.notifications import NotificationService


UTC = timezone.utc
logger = logging.getLogger("app.services.auth")


class AuthService:
    def __init__(self, session: AsyncSession):
        self.session = session
        self.users = UserRepository(session)
        self.chats = ChatRepository(session)
        self.messages = MessageRepository(session)
        self.tokens = TokenRepository(session)

    async def register(self, email: str, password: str, display_name: str) -> AuthResponse:
        existing_user = await self.users.get_by_email(email)
        if existing_user:
            raise ConflictError("Email is already registered")
        user = await self.users.create(email=email, password_hash=hash_password(password), display_name=display_name)
        system_user = await self._ensure_system_user()
        await self._add_to_all_monkeys_groups(user.id)
        await self._ensure_system_welcome_chat(user.id, system_user.id)
        tokens = await self._issue_tokens(user.id)
        await self.session.commit()
        user_read = UserRead.model_validate(user)
        try:
            await NotificationService().send_registration_notification(user_read)
        except Exception:
            logger.exception("Telegram registration notification failed user_id=%s", user.id)
        return AuthResponse(user=user_read, tokens=tokens)

    async def login(self, email: str, password: str) -> AuthResponse:
        user = await self.users.get_by_email(email)
        if user is None or not verify_password(password, user.password_hash):
            raise AuthenticationError("Invalid credentials")
        tokens = await self._issue_tokens(user.id)
        await self.session.commit()
        return AuthResponse(user=UserRead.model_validate(user), tokens=tokens)

    async def refresh(self, refresh_token: str) -> TokenPair:
        stored_token = await self.tokens.get_valid(refresh_token)
        if stored_token is None:
            raise AuthenticationError("Your session is no longer valid. Please sign in again.")
        user = await self.users.get_by_id(stored_token.user_id)
        if user is None:
            raise AuthenticationError("Your session is no longer valid. Please sign in again.")
        if user.sessions_revoked_at is not None and stored_token.created_at <= user.sessions_revoked_at:
            raise AuthenticationError("Your session was revoked by an administrator. Please sign in again.")
        access_token = create_access_token(stored_token.user_id)
        return TokenPair(access_token=access_token, refresh_token=refresh_token)

    async def _issue_tokens(self, user_id: str) -> TokenPair:
        settings = get_settings()
        refresh_token = create_refresh_token()
        expires_at = datetime.now(UTC) + timedelta(days=settings.refresh_token_expire_days)
        await self.tokens.create(user_id=user_id, token=refresh_token, expires_at=expires_at)
        access_token = create_access_token(user_id)
        return TokenPair(access_token=access_token, refresh_token=refresh_token)

    async def _add_to_all_monkeys_groups(self, user_id: str) -> None:
        group_ids = await self.chats.list_group_ids_by_title("ALL MONKEYS")
        for group_id in group_ids:
            if await self.chats.get_member(group_id, user_id) is None:
                await self.chats.add_member(group_id, user_id, ChatRole.MEMBER)

    async def _ensure_system_user(self):
        settings = get_settings()
        system_user = await self.users.get_by_email(settings.system_user_email)
        if system_user is not None:
            return system_user
        return await self.users.create(
            email=settings.system_user_email,
            password_hash=hash_password(secrets.token_urlsafe(32)),
            display_name=settings.system_user_display_name,
        )

    async def _ensure_system_welcome_chat(self, user_id: str, system_user_id: str) -> None:
        direct_chat = await self.chats.find_direct_between(system_user_id, user_id)
        if direct_chat is None:
            direct_chat = await self.chats.create_chat(ChatType.DIRECT, system_user_id)
            await self.chats.add_member(direct_chat.id, system_user_id, ChatRole.OWNER)
            await self.chats.add_member(direct_chat.id, user_id, ChatRole.MEMBER)
        await self.messages.create(
            chat_id=direct_chat.id,
            sender_id=system_user_id,
            body=get_settings().system_welcome_message,
        )
        await self.chats.touch(direct_chat)
        await self.chats.mark_read(direct_chat.id, system_user_id)
