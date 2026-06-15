import logging
from pathlib import Path
from uuid import uuid4

from fastapi import UploadFile

from app.core.settings import get_settings
from app.services.exceptions import ConflictError


logger = logging.getLogger("app.services.storage")


class StorageService:
    allowed_image_content_types = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
    }
    allowed_video_content_types = {
        "video/mp4": ".mp4",
        "video/quicktime": ".mov",
        "video/webm": ".webm",
        "video/x-m4v": ".m4v",
        "video/x-matroska": ".mkv",
    }

    def __init__(self):
        self.settings = get_settings()
        self.root = self.settings.media_root_path

    def ensure_directories(self) -> None:
        (self.root / "avatars").mkdir(parents=True, exist_ok=True)
        (self.root / "group-icons").mkdir(parents=True, exist_ok=True)
        (self.root / "message-images").mkdir(parents=True, exist_ok=True)
        (self.root / "message-videos").mkdir(parents=True, exist_ok=True)
        logger.info("Media directories ensured root=%s", self.root)

    async def save_avatar(self, upload: UploadFile, user_id: str) -> str:
        return await self._save_image(upload, "avatars", user_id)

    async def save_message_image(self, upload: UploadFile, user_id: str) -> str:
        return await self._save_image(upload, "message-images", user_id)

    async def save_message_video(self, upload: UploadFile, user_id: str) -> str:
        return await self._save_video(upload, "message-videos", user_id)

    async def save_group_icon(self, upload: UploadFile, chat_id: str) -> str:
        return await self._save_image(upload, "group-icons", chat_id)

    async def _save_image(self, upload: UploadFile, folder: str, owner_id: str) -> str:
        return await self._save_upload(
            upload,
            folder,
            owner_id,
            allowed_content_types=self.allowed_image_content_types,
            rejected_message="Only jpeg, png, webp, and gif images are supported",
            media_label="Image",
        )

    async def _save_video(self, upload: UploadFile, folder: str, owner_id: str) -> str:
        return await self._save_upload(
            upload,
            folder,
            owner_id,
            allowed_content_types=self.allowed_video_content_types,
            rejected_message="Only mp4, mov, webm, m4v, and mkv videos are supported",
            media_label="Video",
        )

    async def _save_upload(
        self,
        upload: UploadFile,
        folder: str,
        owner_id: str,
        *,
        allowed_content_types: dict[str, str],
        rejected_message: str,
        media_label: str,
    ) -> str:
        content_type = upload.content_type or ""
        suffix = allowed_content_types.get(content_type)
        if suffix is None:
            logger.warning("%s upload rejected owner_id=%s folder=%s content_type=%s", media_label, owner_id, folder, content_type)
            raise ConflictError(rejected_message)
        data = await upload.read()
        if not data:
            logger.warning("%s upload rejected as empty owner_id=%s folder=%s filename=%s", media_label, owner_id, folder, upload.filename)
            raise ConflictError("Uploaded file is empty")
        if len(data) > self.settings.max_upload_size_bytes:
            logger.warning(
                "%s upload rejected as too large owner_id=%s folder=%s filename=%s size=%s limit=%s",
                media_label,
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
            "%s saved owner_id=%s folder=%s filename=%s path=%s size=%s",
            media_label,
            owner_id,
            folder,
            upload.filename,
            target,
            len(data),
        )
        return f"/media/{relative_path.as_posix()}"
