import json
import logging
from datetime import datetime, timedelta, timezone

from livekit import api as livekit_api
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.settings import get_settings
from app.db.repositories import ChatRepository, UserRepository
from app.domain.enums import ChatRole, ChatType
from app.schemas.chat import VoiceJoinRead, VoiceParticipantRead, VoiceStateRead
from app.services.exceptions import AuthorizationError, ConflictError, NotFoundError


logger = logging.getLogger("app.services.voice")
UTC = timezone.utc


class VoiceService:
    def __init__(self, session: AsyncSession):
        self.session = session
        self.chats = ChatRepository(session)
        self.users = UserRepository(session)
        self.settings = get_settings()

    def room_name_for_chat(self, chat_id: str) -> str:
        return f"chat-{chat_id}"

    def chat_id_from_room_name(self, room_name: str) -> str | None:
        prefix = "chat-"
        if not room_name.startswith(prefix):
            return None
        value = room_name[len(prefix):].strip()
        return value or None

    async def create_join(self, chat_id: str, user_id: str) -> VoiceJoinRead:
        self._ensure_voice_enabled()
        chat = await self._ensure_chat_access(chat_id, user_id)
        current_user = await self.users.get_by_id(user_id)
        if current_user is None:
            raise NotFoundError("User not found")
        room_name = self.room_name_for_chat(chat_id)
        metadata = json.dumps(
            {
                "user_id": current_user.id,
                "chat_id": chat_id,
                "avatar_url": self._absolute_url(current_user.avatar_url),
            }
        )
        token = (
            livekit_api.AccessToken(self.settings.livekit_api_key, self.settings.livekit_api_secret)
            .with_identity(current_user.id)
            .with_name(current_user.display_name)
            .with_metadata(metadata)
            .with_grants(
                livekit_api.VideoGrants(
                    room_join=True,
                    room=room_name,
                    can_publish=True,
                    can_publish_data=True,
                    can_subscribe=True,
                )
            )
            .with_ttl(timedelta(hours=6))
            .to_jwt()
        )
        state = await self.get_state(chat_id, user_id)
        return VoiceJoinRead(
            chat_id=chat_id,
            room_name=room_name,
            server_url=self.settings.voice_public_url or self.settings.livekit_url,
            participant_token=token,
            participant_identity=current_user.id,
            state=state,
        )

    async def get_state(self, chat_id: str, user_id: str) -> VoiceStateRead:
        self._ensure_voice_enabled()
        await self._ensure_chat_access(chat_id, user_id)
        return await self.get_state_for_chat(chat_id)

    async def get_state_for_chat(self, chat_id: str) -> VoiceStateRead:
        room_name = self.room_name_for_chat(chat_id)
        participants = await self._fetch_participants(room_name)
        return VoiceStateRead(
            chat_id=chat_id,
            room_name=room_name,
            room_active=bool(participants),
            participants=participants,
            updated_at=datetime.now(UTC),
        )

    async def voice_member_user_ids(self, chat_id: str) -> list[str]:
        return await self.chats.list_member_user_ids(chat_id)

    async def mute_participant(self, chat_id: str, actor_user_id: str, target_user_id: str) -> VoiceStateRead:
        chat = await self._ensure_moderation_access(chat_id, actor_user_id, target_user_id)
        room_name = self.room_name_for_chat(chat_id)
        participant = await self._get_room_participant(room_name, target_user_id)
        track_sids = [
            getattr(track, "sid", "")
            for track in getattr(participant, "tracks", [])
            if getattr(track, "sid", "")
        ]
        if not track_sids:
            logger.warning(
                "Voice participant mute rejected because no published tracks were found chat_id=%s actor_id=%s target_user_id=%s",
                chat_id,
                actor_user_id,
                target_user_id,
            )
            raise ConflictError("User has no published voice tracks")
        try:
            async with livekit_api.LiveKitAPI(
                url=self.settings.livekit_url,
                api_key=self.settings.livekit_api_key,
                api_secret=self.settings.livekit_api_secret,
            ) as client:
                for track_sid in track_sids:
                    await client.room.mute_published_track(
                        livekit_api.MuteRoomTrackRequest(
                            room=room_name,
                            identity=target_user_id,
                            track_sid=track_sid,
                            muted=True,
                        )
                    )
        except Exception as error:
            logger.warning(
                "Voice participant mute failed chat_id=%s actor_id=%s target_user_id=%s detail=%s",
                chat_id,
                actor_user_id,
                target_user_id,
                error,
            )
            raise ConflictError("Unable to mute this participant right now") from error
        logger.info(
            "Voice participant muted chat_id=%s actor_id=%s target_user_id=%s tracks=%s",
            chat_id,
            actor_user_id,
            target_user_id,
            len(track_sids),
        )
        return await self.get_state_for_chat(chat_id)

    async def kick_participant(self, chat_id: str, actor_user_id: str, target_user_id: str) -> VoiceStateRead:
        chat = await self._ensure_moderation_access(chat_id, actor_user_id, target_user_id)
        room_name = self.room_name_for_chat(chat_id)
        await self._get_room_participant(room_name, target_user_id)
        try:
            async with livekit_api.LiveKitAPI(
                url=self.settings.livekit_url,
                api_key=self.settings.livekit_api_key,
                api_secret=self.settings.livekit_api_secret,
            ) as client:
                await client.room.remove_participant(
                    livekit_api.RoomParticipantIdentity(
                        room=room_name,
                        identity=target_user_id,
                    )
                )
        except Exception as error:
            logger.warning(
                "Voice participant kick failed chat_id=%s actor_id=%s target_user_id=%s detail=%s",
                chat_id,
                actor_user_id,
                target_user_id,
                error,
            )
            raise ConflictError("Unable to remove this participant right now") from error
        logger.info(
            "Voice participant removed chat_id=%s actor_id=%s target_user_id=%s",
            chat_id,
            actor_user_id,
            target_user_id,
        )
        return await self.get_state_for_chat(chat_id)

    async def _ensure_chat_access(self, chat_id: str, user_id: str):
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Voice room target chat not found chat_id=%s actor_id=%s", chat_id, user_id)
            raise NotFoundError("Chat not found")
        membership = await self.chats.get_member(chat_id, user_id)
        if membership is None and not await self.users.is_admin(user_id):
            logger.warning("Voice room access forbidden chat_id=%s actor_id=%s", chat_id, user_id)
            raise AuthorizationError("You are not a member of this chat")
        return chat

    async def _ensure_moderation_access(self, chat_id: str, actor_user_id: str, target_user_id: str):
        chat = await self.chats.get_by_id(chat_id)
        if chat is None:
            logger.warning("Voice moderation target chat not found chat_id=%s actor_id=%s", chat_id, actor_user_id)
            raise NotFoundError("Chat not found")
        if chat.type != ChatType.GROUP:
            logger.warning("Voice moderation attempted on non-group chat chat_id=%s actor_id=%s", chat_id, actor_user_id)
            raise ConflictError("Voice moderation is available only in group chats")
        if actor_user_id == target_user_id:
            logger.warning("Voice moderation self-target rejected chat_id=%s actor_id=%s", chat_id, actor_user_id)
            raise ConflictError("You cannot moderate yourself")
        membership = await self.chats.get_member(chat_id, actor_user_id)
        is_admin = await self.users.is_admin(actor_user_id)
        if not is_admin and (membership is None or membership.role != ChatRole.OWNER):
            logger.warning("Voice moderation forbidden chat_id=%s actor_id=%s", chat_id, actor_user_id)
            raise AuthorizationError("Only the group owner can moderate voice participants")
        target_user = await self.users.get_by_id(target_user_id)
        if target_user is None:
            logger.warning(
                "Voice moderation target user not found chat_id=%s actor_id=%s target_user_id=%s",
                chat_id,
                actor_user_id,
                target_user_id,
            )
            raise NotFoundError("User not found")
        return chat

    async def _get_room_participant(self, room_name: str, user_id: str):
        try:
            async with livekit_api.LiveKitAPI(
                url=self.settings.livekit_url,
                api_key=self.settings.livekit_api_key,
                api_secret=self.settings.livekit_api_secret,
            ) as client:
                return await client.room.get_participant(
                    livekit_api.RoomParticipantIdentity(
                        room=room_name,
                        identity=user_id,
                    )
                )
        except Exception as error:
            logger.warning(
                "Voice participant lookup failed room_name=%s target_user_id=%s detail=%s",
                room_name,
                user_id,
                error,
            )
            raise NotFoundError("User is not in voice right now") from error

    async def _fetch_participants(self, room_name: str) -> list[VoiceParticipantRead]:
        try:
            async with livekit_api.LiveKitAPI(
                url=self.settings.livekit_url,
                api_key=self.settings.livekit_api_key,
                api_secret=self.settings.livekit_api_secret,
            ) as client:
                response = await client.room.list_participants(
                    livekit_api.ListParticipantsRequest(room=room_name)
                )
        except Exception:
            logger.info("Voice room state empty or unavailable room_name=%s", room_name, exc_info=True)
            return []
        identities = [participant.identity for participant in response.participants if getattr(participant, "identity", "")]
        users_by_id = await self.users.get_by_ids(identities)
        results: list[VoiceParticipantRead] = []
        for participant in response.participants:
            identity = getattr(participant, "identity", "")
            user = users_by_id.get(identity)
            if user is None:
                continue
            results.append(
                VoiceParticipantRead(
                    user=user,
                    joined_at=self._participant_joined_at(participant),
                    is_muted=bool(getattr(participant, "is_muted", False)),
                )
            )
        return results

    def _participant_joined_at(self, participant: object) -> datetime:
        raw_value = getattr(participant, "joined_at", None)
        if isinstance(raw_value, datetime):
            return raw_value if raw_value.tzinfo is not None else raw_value.replace(tzinfo=UTC)
        if isinstance(raw_value, (int, float)):
            if raw_value > 1_000_000_000_000:
                raw_value = raw_value / 1000
            return datetime.fromtimestamp(raw_value, tz=UTC)
        return datetime.now(UTC)

    def _ensure_voice_enabled(self) -> None:
        if self.settings.voice_enabled:
            return
        logger.warning("Voice feature is disabled because LiveKit settings are incomplete")
        raise ConflictError("Voice chat is not configured")

    def _absolute_url(self, value: str | None) -> str | None:
        if not value:
            return value
        if value.startswith("http://") or value.startswith("https://"):
            return value
        return f"{self.settings.public_base_url.rstrip('/')}{value}"
