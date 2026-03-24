from pathlib import Path
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Messenger Backend"
    app_env: str = "development"
    database_url: str = "postgresql+asyncpg://messenger:messenger@localhost:5432/messenger"
    jwt_secret: str = "change-me"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 14
    app_host: str = "127.0.0.1"
    app_port: int = 8000
    log_level: str = "INFO"
    public_base_url: str = "http://127.0.0.1:8000"
    cors_allow_origins: str = "*"
    media_root: str = "storage"
    max_upload_size_bytes: int = 10 * 1024 * 1024
    telegram_notifications_enabled: bool = False
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    telegram_proxy_url: str = ""
    push_notifications_enabled: bool = False
    firebase_credentials_path: str = ""
    livekit_url: str = ""
    livekit_api_key: str = ""
    livekit_api_secret: str = ""
    livekit_webhook_key: str = ""
    voice_public_url: str = ""
    system_user_email: str = "system@kaftar.kuchizu.com"
    system_user_display_name: str = "Kaftar"
    system_welcome_message: str = "Welcome to Kaftar. Here you'll receive important updates and news."
    admin_user_email: str = "admin@kuchizu.com"

    @property
    def voice_enabled(self) -> bool:
        return bool(self.livekit_url and self.livekit_api_key and self.livekit_api_secret)

    @property
    def firebase_enabled(self) -> bool:
        return bool(self.push_notifications_enabled and self.firebase_credentials_path)

    @property
    def media_root_path(self) -> Path:
        return Path(self.media_root).resolve()

    @property
    def cors_allow_origins_list(self) -> list[str]:
        value = self.cors_allow_origins.strip()
        if not value or value == "*":
            return ["*"]
        return [item.strip() for item in value.split(",") if item.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
