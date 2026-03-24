from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class PushDeviceTokenRegisterRequest(BaseModel):
    token: str = Field(min_length=32, max_length=512)
    platform: str = Field(min_length=2, max_length=32)


class PushDeviceTokenUnregisterRequest(BaseModel):
    token: str = Field(min_length=32, max_length=512)


class PushDeviceTokenRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    token: str
    platform: str
    created_at: datetime
    updated_at: datetime
