import logging
from pathlib import Path
from uuid import uuid4

from fastapi import UploadFile

from app.core.settings import get_settings
from app.services.exceptions import ConflictError


logger = logging.getLogger("app.services.storage")


class StorageService:
    allowed_content_types = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
    }

    def __init__(self):
        self.settings = get_settings()
        self.root = self.settings.media_root_path

    def ensure_directories(self) -> None:
        (self.root / "avatars").mkdir(parents=True, exist_ok=True)
        (self.root / "group-icons").mkdir(parents=True, exist_ok=True)
        (self.root / "message-images").mkdir(parents=True, exist_ok=True)
        logger.info("Media directories ensured root=%s", self.root)

    async def save_avatar(self, upload: UploadFile, user_id: str) -> str:
        return await self._save_image(upload, "avatars", user_id)

    async def save_message_image(self, upload: UploadFile, user_id: str) -> str:
        return await self._save_image(upload, "message-images", user_id)

    async def save_group_icon(self, upload: UploadFile, chat_id: str) -> str:
        return await self._save_image(upload, "group-icons", chat_id)

    async def _save_image(self, upload: UploadFile, folder: str, owner_id: str) -> str:
        content_type = upload.content_type or ""
        suffix = self.allowed_content_types.get(content_type)
        if suffix is None:
            logger.warning("Image upload rejected owner_id=%s folder=%s content_type=%s", owner_id, folder, content_type)
            raise ConflictError("Only jpeg, png, webp, and gif images are supported")
        data = await upload.read()
        if not data:
            logger.warning("Image upload rejected as empty owner_id=%s folder=%s filename=%s", owner_id, folder, upload.filename)
            raise ConflictError("Uploaded file is empty")
        if len(data) > self.settings.max_upload_size_bytes:
            logger.warning(
                "Image upload rejected as too large owner_id=%s folder=%s filename=%s size=%s limit=%s",
                owner_id,
                folder,
                upload.filename,
                len(data),
                self.settings.max_upload_size_bytes,
            )
            raise ConflictError("Uploaded file exceeds size limit")
        relative_path = Path(folder) / f"{owner_id}-{uuid4().hex}{suffix}"
        target = self.root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        logger.info(
            "Image saved owner_id=%s folder=%s filename=%s path=%s size=%s",
            owner_id,
            folder,
            upload.filename,
            target,
            len(data),
        )
        return f"/media/{relative_path.as_posix()}"
