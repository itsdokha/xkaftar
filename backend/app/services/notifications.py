import logging
from datetime import datetime, timezone

import httpx

from app.core.settings import get_settings
from app.schemas.auth import UserRead


logger = logging.getLogger("app.services.notifications")


class NotificationService:
    def __init__(self):
        self.settings = get_settings()

    async def send_registration_notification(self, user: UserRead) -> None:
        if not self.settings.telegram_notifications_enabled:
            return
        if not self.settings.telegram_bot_token or not self.settings.telegram_chat_id:
            logger.warning("Telegram notifications are enabled but bot token or chat id is missing")
            return
        url = f"https://api.telegram.org/bot{self.settings.telegram_bot_token}/sendMessage"
        registered_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        text = (
            "New registration\n\n"
            f"Display name: {user.display_name}\n"
            f"Email: {user.email}\n"
            f"User ID: {user.id}\n"
            f"Registered at: {registered_at}"
        )
        client_kwargs = {"timeout": 10.0}
        if self.settings.telegram_proxy_url.strip():
            client_kwargs["proxy"] = self.settings.telegram_proxy_url.strip()
        async with httpx.AsyncClient(**client_kwargs) as client:
            response = await client.post(
                url,
                json={
                    "chat_id": self.settings.telegram_chat_id,
                    "text": text,
                },
            )
            response.raise_for_status()
        logger.info("Telegram registration notification sent user_id=%s", user.id)
