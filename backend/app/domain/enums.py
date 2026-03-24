from enum import Enum

try:
    from enum import StrEnum
except ImportError:
    class StrEnum(str, Enum):
        pass


class ChatType(StrEnum):
    DIRECT = "direct"
    GROUP = "group"


class ChatRole(StrEnum):
    OWNER = "owner"
    MEMBER = "member"


class MessageKind(StrEnum):
    USER = "user"
    SYSTEM = "system"
