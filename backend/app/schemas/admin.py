from datetime import datetime

from pydantic import BaseModel


class AdminSessionRevokeRead(BaseModel):
    user_id: str
    revoked_at: datetime
