import logging

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.settings import get_settings
from app.db.repositories import ChatRepository, MessageRepository, UserRepository
from app.domain.enums import ChatRole, ChatType, MessageKind
from app.schemas.chat import ChatRead, MessagePageRead, MessageRead
from app.services.exceptions import AuthorizationError, ConflictError, NotFoundError
from app.services.serializers import chat_to_schema, message_to_schema


logger = logging.getLogger("app.services.chats")


class ChatService:
    def __init__(self, session: AsyncSession):
        self.session = session
        self.chats = ChatRepository(session)
        self.messages = MessageRepository(session)
        self.users = UserRepository(session)

    async def list_chats(self, user_id: str) -> list[ChatRead]:
        chats = await self.chats.list_all_chats() if await self._is_admin_user(user_id) else await self.chats.list_for_user(user_id)
        return await self._serialize_chats(chats, user_id)

    async def create_direct_chat(self, current_user_id: str, other_email: str) -> ChatRead:
        other_user = await self.users.get_by_email(other_email)
        if other_user is None:
            logger.warning("Direct chat target not found actor_id=%s email=%s", current_user_id, other_email)
            raise NotFoundError("User not found")
        if other_user.id == current_user_id:
            logger.warning("Direct chat with self actor_id=%s", current_user_id)
            raise ConflictError("Cannot create direct chat with yourself")
        existing = await self.chats.find_direct_between(current_user_id, other_user.id)
        if existing is not None:
            logger.info("Direct chat reused actor_id=%s other_user_id=%s chat_id=%s", current_user_id, other_user.id, existing.id)
            return await self._serialize_chat(existing, current_user_id)
        chat = await self.chats.create_chat(ChatType.DIRECT, current_user_id)
        await self.chats.add_member(chat.id, current_user_id, ChatRole.OWNER)
        await self.chats.add_member(chat.id, other_user.id, ChatRole.MEMBER)
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat.id)
        logger.info("Direct chat stored actor_id=%s other_user_id=%s chat_id=%s", current_user_id, other_user.id, chat.id)
        return await self._serialize_chat(loaded_chat, current_user_id)

    async def create_group_chat(self, current_user_id: str, title: str, member_emails: list[str]) -> ChatRead:
        chat = await self.chats.create_chat(ChatType.GROUP, current_user_id, title=title)
        await self.chats.add_member(chat.id, current_user_id, ChatRole.OWNER)
        added_user_ids = {current_user_id}
        logger.info("Group chat creation started actor_id=%s chat_id=%s title=%s", current_user_id, chat.id, title)
        if self._is_all_monkeys_group(title):
            for user_id in await self.users.list_all_ids():
                if user_id not in added_user_ids:
                    await self.chats.add_member(chat.id, user_id, ChatRole.MEMBER)
                    added_user_ids.add(user_id)
        for email in member_emails:
            user = await self.users.get_by_email(email)
            if user and user.id not in added_user_ids:
                await self.chats.add_member(chat.id, user.id, ChatRole.MEMBER)
                added_user_ids.add(user.id)
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat.id)
        logger.info("Group chat stored actor_id=%s chat_id=%s members=%s", current_user_id, chat.id, len(added_user_ids))
        return await self._serialize_chat(loaded_chat, current_user_id)

    async def get_chat(self, chat_id: str, current_user_id: str) -> ChatRead:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Chat lookup not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if not await self._is_admin_user(current_user_id) and all(member.user_id != current_user_id for member in chat.members):
            logger.warning("Chat lookup forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        return await self._serialize_chat(chat, current_user_id)

    async def add_member(self, chat_id: str, current_user_id: str, email: str) -> tuple[ChatRead, MessageRead]:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Add member target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Add member attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Members can be added only to group chats")
        current_membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if not await self._is_admin_user(current_user_id) and (current_membership is None or current_membership.role != ChatRole.OWNER):
            logger.warning("Add member forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("Only the group owner can add members")
        user = await self.users.get_by_email(email)
        if user is None:
            logger.warning("Add member target not found chat_id=%s actor_id=%s email=%s", chat_id, current_user_id, email)
            raise NotFoundError("User not found")
        existing_member = await self.chats.get_member(chat_id, user.id)
        if existing_member is not None:
            logger.warning("Add member duplicate chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user_id, user.id)
            raise ConflictError("User is already a member")
        await self.chats.add_member(chat_id, user.id, ChatRole.MEMBER)
        await self.chats.touch(chat)
        system_message = await self._create_system_message(
            chat_id=chat_id,
            actor_user_id=current_user_id,
            body=f"added {user.display_name} to the group",
        )
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat_id)
        logger.info("Add member stored chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user_id, user.id)
        return await self._serialize_chat(loaded_chat, current_user_id), system_message

    async def update_group_icon(self, chat_id: str, current_user_id: str, icon_url: str) -> ChatRead:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Group icon target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Group icon update attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Icon can be updated only for group chats")
        current_membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if current_membership is None and not await self._is_admin_user(current_user_id):
            logger.warning("Group icon update forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("Only group members can update the icon")
        await self.chats.update_icon(chat, icon_url)
        await self.chats.touch(chat)
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat_id)
        logger.info("Group icon stored chat_id=%s actor_id=%s", chat_id, current_user_id)
        return await self._serialize_chat(loaded_chat, current_user_id)

    async def rename_group(self, chat_id: str, current_user_id: str, title: str) -> tuple[ChatRead, MessageRead]:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Group rename target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Group rename attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Only groups can be renamed")
        current_membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if not await self._is_admin_user(current_user_id) and (current_membership is None or current_membership.role != ChatRole.OWNER):
            logger.warning("Group rename forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("Only the group owner can rename the group")
        normalized_title = title.strip()
        if len(normalized_title) < 2:
            raise ConflictError("Group title is too short")
        previous_title = chat.title or "Untitled group"
        await self.chats.rename(chat, normalized_title)
        await self.chats.touch(chat)
        system_message = await self._create_system_message(
            chat_id=chat_id,
            actor_user_id=current_user_id,
            body=f'renamed the group from "{previous_title}" to "{normalized_title}"',
        )
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat_id)
        logger.info("Group renamed chat_id=%s actor_id=%s title=%s", chat_id, current_user_id, normalized_title)
        return await self._serialize_chat(loaded_chat, current_user_id), system_message

    async def leave_group(self, chat_id: str, current_user_id: str) -> tuple[list[str], MessageRead, str]:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Leave group target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Leave group attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Only groups can be left")
        membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if membership is None:
            logger.warning("Leave group forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        if membership.role == ChatRole.OWNER:
            logger.warning("Leave group forbidden for owner chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Group owner must delete the group instead of leaving")
        member_user_ids = [member.user_id for member in chat.members]
        system_message = await self._create_system_message(
            chat_id=chat_id,
            actor_user_id=current_user_id,
            body="left the group",
        )
        await self.chats.remove_member(membership)
        await self.chats.touch(chat)
        await self.session.commit()
        logger.info("Left group chat_id=%s actor_id=%s", chat_id, current_user_id)
        return member_user_ids, system_message, chat.title or "Untitled group"

    async def delete_group(self, chat_id: str, current_user_id: str) -> tuple[list[str], str]:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Delete group target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Delete group attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Only groups can be deleted")
        membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if not await self._is_admin_user(current_user_id) and (membership is None or membership.role != ChatRole.OWNER):
            logger.warning("Delete group forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("Only the group owner can delete the group")
        member_user_ids = [member.user_id for member in chat.members]
        title = chat.title or "Untitled group"
        await self.chats.delete_chat(chat)
        await self.session.commit()
        logger.info("Group deleted chat_id=%s actor_id=%s", chat_id, current_user_id)
        return member_user_ids, title

    async def remove_member_from_group(
        self,
        chat_id: str,
        current_user_id: str,
        target_user_id: str,
    ) -> tuple[list[str], MessageRead, str, str]:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Remove member target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Remove member attempted on direct chat chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Members can be removed only from group chats")
        current_membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        if not await self._is_admin_user(current_user_id) and (current_membership is None or current_membership.role != ChatRole.OWNER):
            logger.warning("Remove member forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("Only the group owner can remove members")
        membership = next((member for member in chat.members if member.user_id == target_user_id), None)
        if membership is None:
            logger.warning("Remove member target missing chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user_id, target_user_id)
            raise NotFoundError("User is not a member of this chat")
        if membership.role == ChatRole.OWNER:
            logger.warning("Remove member forbidden for owner chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user_id, target_user_id)
            raise ConflictError("The group owner cannot be removed")
        if membership.user_id == current_user_id:
            logger.warning("Remove member self-target chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Use leave group instead")
        member_user_ids = [member.user_id for member in chat.members]
        removed_display_name = membership.user.display_name
        system_message = await self._create_system_message(
            chat_id=chat_id,
            actor_user_id=current_user_id,
            body=f"removed {removed_display_name} from the group",
        )
        await self.chats.remove_member(membership)
        await self.chats.touch(chat)
        await self.session.commit()
        logger.info(
            "Removed member chat_id=%s actor_id=%s target_user_id=%s",
            chat_id,
            current_user_id,
            target_user_id,
        )
        return member_user_ids, system_message, chat.title or "Untitled group", removed_display_name

    async def update_notifications_enabled(self, chat_id: str, current_user_id: str, enabled: bool) -> ChatRead:
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Notifications target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        membership = await self.chats.set_notifications_enabled(chat_id, current_user_id, enabled)
        if membership is None:
            logger.warning("Notifications forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        await self.session.commit()
        loaded_chat = await self.chats.get_by_id(chat_id)
        logger.info(
            "Notifications setting stored chat_id=%s actor_id=%s enabled=%s",
            chat_id,
            current_user_id,
            enabled,
        )
        return await self._serialize_chat(loaded_chat, current_user_id)

    async def list_messages(
        self,
        chat_id: str,
        current_user_id: str,
        limit: int = 50,
        before_message_id: str | None = None,
    ) -> tuple[MessagePageRead, bool]:
        membership = await self.chats.get_member(chat_id, current_user_id)
        is_admin = await self._is_admin_user(current_user_id)
        if membership is None and not is_admin:
            logger.warning("Messages list forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        previous_last_read_at = membership.last_read_at if membership is not None else None
        updated_membership = await self.chats.mark_read(chat_id, current_user_id) if membership is not None else None
        await self.session.commit()
        total = await self.messages.count_for_chat(chat_id)
        messages = await self.messages.list_for_chat(chat_id, limit=limit, before_message_id=before_message_id)
        read_state_changed = updated_membership is not None and updated_membership.last_read_at != previous_last_read_at
        has_more = False
        next_before_message_id = None
        if messages:
            has_more = bool(await self.messages.list_for_chat(chat_id, limit=1, before_message_id=messages[0].id))
            if has_more:
                next_before_message_id = messages[0].id
        page = MessagePageRead(
            items=[message_to_schema(message) for message in messages],
            total=total,
            has_more=has_more,
            next_before_message_id=next_before_message_id,
        )
        logger.info(
            "Messages page built chat_id=%s actor_id=%s total=%s page_count=%s has_more=%s",
            chat_id,
            current_user_id,
            total,
            len(page.items),
            has_more,
        )
        return page, read_state_changed

    async def mark_read(self, chat_id: str, current_user_id: str) -> tuple[ChatRead, bool]:
        membership = await self.chats.get_member(chat_id, current_user_id)
        is_admin = await self._is_admin_user(current_user_id)
        if membership is None and not is_admin:
            logger.warning("Read mark forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        previous_last_read_at = membership.last_read_at if membership is not None else None
        updated_membership = await self.chats.mark_read(chat_id, current_user_id) if membership is not None else None
        await self.session.commit()
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Read mark target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        read_state_changed = updated_membership is not None and updated_membership.last_read_at != previous_last_read_at
        return await self._serialize_chat(chat, current_user_id), read_state_changed

    async def create_message(
        self,
        chat_id: str,
        current_user_id: str,
        body: str,
        image_url: str | None = None,
        reply_to_message_id: str | None = None,
        client_message_id: str | None = None,
    ) -> MessageRead:
        membership = await self.chats.get_member(chat_id, current_user_id)
        is_admin = await self._is_admin_user(current_user_id)
        if membership is None and not is_admin:
            logger.warning("Message creation forbidden chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise AuthorizationError("You are not a member of this chat")
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Message creation target chat not found chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise NotFoundError("Chat not found")
        if chat.type == ChatType.DIRECT:
            system_email = get_settings().system_user_email.lower()
            counterpart = next((member.user for member in chat.members if member.user_id != current_user_id), None)
            if counterpart is not None and counterpart.email.lower() == system_email:
                logger.warning("Message creation blocked for system chat chat_id=%s actor_id=%s", chat_id, current_user_id)
                raise AuthorizationError("You cannot send messages to this account")
        normalized_body = body.strip()
        normalized_client_message_id = client_message_id.strip() if client_message_id is not None else None
        if normalized_client_message_id == "":
            normalized_client_message_id = None
        if normalized_client_message_id is not None:
            existing_message = await self.messages.get_by_client_message_id(
                chat_id,
                current_user_id,
                normalized_client_message_id,
            )
            if existing_message is not None:
                if membership is not None:
                    await self.chats.mark_read(chat_id, current_user_id)
                    await self.session.commit()
                logger.info(
                    "Message create idempotent hit chat_id=%s actor_id=%s message_id=%s client_message_id=%s",
                    chat_id,
                    current_user_id,
                    existing_message.id,
                    normalized_client_message_id,
                )
                return message_to_schema(existing_message)
        if not normalized_body and image_url is None:
            logger.warning("Message creation rejected as empty chat_id=%s actor_id=%s", chat_id, current_user_id)
            raise ConflictError("Message body or image is required")
        if reply_to_message_id is not None:
            reply_target = await self.messages.get_by_id(reply_to_message_id)
            if (
                reply_target is None
                or reply_target.chat_id != chat_id
                or reply_target.deleted_at is not None
                or reply_target.kind == MessageKind.SYSTEM
            ):
                logger.warning(
                    "Message reply target invalid chat_id=%s actor_id=%s reply_to_message_id=%s",
                    chat_id,
                    current_user_id,
                    reply_to_message_id,
                )
                raise ConflictError("Reply target not found")
        await self.messages.create(
            chat_id=chat_id,
            sender_id=current_user_id,
            body=normalized_body,
            image_url=image_url,
            reply_to_message_id=reply_to_message_id,
            client_message_id=normalized_client_message_id,
        )
        await self.chats.touch(chat)
        if membership is not None:
            await self.chats.mark_read(chat_id, current_user_id)
        await self.session.commit()
        refreshed_message = (await self.messages.list_for_chat(chat_id, limit=1))[0]
        logger.info(
            "Message stored chat_id=%s actor_id=%s message_id=%s has_image=%s reply_to_message_id=%s",
            chat_id,
            current_user_id,
            refreshed_message.id,
            image_url is not None,
            reply_to_message_id,
        )
        return message_to_schema(refreshed_message)

    async def _create_system_message(self, chat_id: str, actor_user_id: str, body: str) -> MessageRead:
        await self.messages.create(
            chat_id=chat_id,
            sender_id=actor_user_id,
            body=body,
            kind=MessageKind.SYSTEM,
        )
        refreshed_message = (await self.messages.list_for_chat(chat_id, limit=1))[0]
        return message_to_schema(refreshed_message)

    async def _serialize_chat(self, chat, current_user_id: str) -> ChatRead:
        latest_by_chat = await self.messages.get_latest_for_chats([chat.id])
        unread_counts = await self.chats.get_unread_counts([chat.id], current_user_id)
        membership = next((member for member in chat.members if member.user_id == current_user_id), None)
        return chat_to_schema(
            chat,
            last_message=latest_by_chat.get(chat.id),
            unread_count=unread_counts.get(chat.id, 0),
            notifications_enabled=membership.notifications_enabled if membership is not None else True,
        )

    async def _serialize_chats(self, chats, current_user_id: str) -> list[ChatRead]:
        chat_ids = [chat.id for chat in chats]
        latest_by_chat = await self.messages.get_latest_for_chats(chat_ids)
        unread_counts = await self.chats.get_unread_counts(chat_ids, current_user_id)
        return [
            chat_to_schema(
                chat,
                last_message=latest_by_chat.get(chat.id),
                unread_count=unread_counts.get(chat.id, 0),
                notifications_enabled=next(
                    (
                        member.notifications_enabled
                        for member in chat.members
                        if member.user_id == current_user_id
                    ),
                    True,
                ),
            )
            for chat in chats
        ]

    async def add_reaction(self, message_id: str, user_id: str, emoji: str) -> MessageRead:
        message = await self.messages.get_by_id(message_id)
        if message is None:
            raise NotFoundError("Message not found")
        membership = await self.chats.get_member(message.chat_id, user_id)
        is_admin = await self._is_admin_user(user_id)
        if membership is None and not is_admin:
            raise AuthorizationError("You are not a member of this chat")
        await self.messages.add_reaction(message_id, user_id, emoji)
        await self.session.commit()
        refreshed = await self.messages.get_by_id(message_id, populate_existing=True)
        logger.info("Reaction added message_id=%s user_id=%s emoji=%s", message_id, user_id, emoji)
        return message_to_schema(refreshed)

    async def remove_reaction(self, message_id: str, user_id: str, emoji: str) -> MessageRead:
        message = await self.messages.get_by_id(message_id)
        if message is None:
            raise NotFoundError("Message not found")
        membership = await self.chats.get_member(message.chat_id, user_id)
        is_admin = await self._is_admin_user(user_id)
        if membership is None and not is_admin:
            raise AuthorizationError("You are not a member of this chat")
        await self.messages.remove_reaction(message_id, user_id, emoji)
        await self.session.commit()
        refreshed = await self.messages.get_by_id(message_id, populate_existing=True)
        logger.info("Reaction removed message_id=%s user_id=%s emoji=%s", message_id, user_id, emoji)
        return message_to_schema(refreshed)

    async def _is_admin_user(self, user_id: str) -> bool:
        return await self.users.is_admin(user_id)

    def _is_all_monkeys_group(self, title: str) -> bool:
        return title.strip().casefold() == "all monkeys"
