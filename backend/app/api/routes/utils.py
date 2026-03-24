import logging
import re
from html.parser import HTMLParser

import httpx
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.api.dependencies import get_current_user

router = APIRouter()
logger = logging.getLogger("app.api.utils")

_FETCH_TIMEOUT = 5.0
_MAX_BODY_BYTES = 256_000


class LinkPreviewResponse(BaseModel):
    url: str
    title: str | None = None
    description: str | None = None
    image_url: str | None = None
    site_name: str | None = None


class _OGMetaParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.og: dict[str, str] = {}
        self.title: str | None = None
        self._in_title = False
        self._title_parts: list[str] = []
        self._meta_description: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "title":
            self._in_title = True
            self._title_parts = []
        if tag == "meta":
            attr_dict = {k.lower(): v for k, v in attrs if v is not None}
            prop = attr_dict.get("property", "")
            name = attr_dict.get("name", "")
            content = attr_dict.get("content", "")
            if prop.startswith("og:") and content:
                self.og[prop[3:]] = content
            if name == "description" and content:
                self._meta_description = content

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title" and self._in_title:
            self._in_title = False
            self.title = "".join(self._title_parts).strip() or None


@router.post("/link-preview")
async def fetch_link_preview(
    url: str,
    _current_user: str = Depends(get_current_user),
) -> LinkPreviewResponse:
    if not re.match(r"^https?://", url, re.IGNORECASE):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid URL")

    try:
        async with httpx.AsyncClient(
            follow_redirects=True,
            timeout=_FETCH_TIMEOUT,
            headers={"User-Agent": "KaftarBot/1.0 (link-preview)"},
        ) as client:
            response = await client.get(url)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Could not fetch URL",
        )

    content_type = response.headers.get("content-type", "")
    if "text/html" not in content_type:
        return LinkPreviewResponse(url=url)

    body = response.text[:_MAX_BODY_BYTES]
    parser = _OGMetaParser()
    try:
        parser.feed(body)
    except Exception:
        pass

    og = parser.og
    return LinkPreviewResponse(
        url=url,
        title=og.get("title") or parser.title,
        description=og.get("description") or parser._meta_description,
        image_url=og.get("image"),
        site_name=og.get("site_name"),
    )
