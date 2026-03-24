import asyncio
import logging
from pathlib import Path
from threading import Lock

import firebase_admin
from firebase_admin import credentials, messaging
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.settings import get_settings
from app.db.repositories import ChatRepository, PushDeviceTokenRepository
from app.schemas.chat import ChatRead, MessageRead


logger = logging.getLogger("app.services.push_notifications")


class PushNotificationService:
    _app = None
    _init_lock = Lock()

    def __init__(self, session: AsyncSession):
        self.session = session
        self.settings = get_settings()
        self.tokens = PushDeviceTokenRepository(session)
        self.chats = ChatRepository(session)

    async def send_message_notifications(
        self,
        *,
        chat: ChatRead,
        message: MessageRead,
        sender_user_id: str,
    ) -> None:
        if not self.settings.firebase_enabled:
            return
        recipient_ids = await self.chats.list_notifiable_user_ids(chat.id, exclude_user_id=sender_user_id)
        device_tokens = await self.tokens.list_for_user_ids(recipient_ids)
        if not device_tokens:
            logger.info("Push skipped because no device tokens were found chat_id=%s", chat.id)
            return
        app = self._ensure_app()
        title = self._notification_title(chat, message)
        body = self._notification_body(message)
        token_values = [device_token.token for device_token in device_tokens]
        await asyncio.to_thread(
            self._send_sync,
            app,
            token_values,
            title,
            body,
            chat.id,
            message.id,
        )
        logger.info(
            "Push message notifications sent chat_id=%s message_id=%s recipients=%s tokens=%s",
            chat.id,
            message.id,
            len(recipient_ids),
            len(token_values),
        )

    def _ensure_app(self):
        if self.__class__._app is not None:
            return self.__class__._app
        with self.__class__._init_lock:
            if self.__class__._app is not None:
                return self.__class__._app
            credentials_path = Path(self.settings.firebase_credentials_path).expanduser().resolve()
            certificate = credentials.Certificate(str(credentials_path))
            self.__class__._app = firebase_admin.initialize_app(certificate)
            logger.info("Firebase admin initialized credentials_path=%s", credentials_path)
            return self.__class__._app

    def _send_sync(
        self,
        app,
        token_values: list[str],
        title: str,
        body: str,
        chat_id: str,
        message_id: str,
    ) -> None:
        for token in token_values:
            try:
                messaging.send(
                    messaging.Message(
                        token=token,
                        notification=messaging.Notification(title=title, body=body),
                        data={
                            "type": "message_created",
                            "chat_id": chat_id,
                            "message_id": message_id,
                        },
                        android=messaging.AndroidConfig(
                            priority="high",
                            notification=messaging.AndroidNotification(
                                channel_id="messages",
                                sound="default",
                            ),
                        ),
                        apns=messaging.APNSConfig(
                            payload=messaging.APNSPayload(
                                aps=messaging.Aps(sound="default"),
                            )
                        ),
                    ),
                    app=app,
                )
            except Exception:
                logger.exception("Push send failed chat_id=%s message_id=%s token_prefix=%s", chat_id, message_id, token[:12])

    def _notification_title(self, chat: ChatRead, message: MessageRead) -> str:
        if chat.type == "group":
            return chat.title or message.sender.display_name
        return message.sender.display_name

    def _notification_body(self, message: MessageRead) -> str:
        if message.image_url and message.body:
            return f"Photo: {message.body}"
        if message.image_url:
            return "Photo"
        if message.body:
            return message.body
        return "New message"
