import argparse
import asyncio

from sqlalchemy import func, select

from app.db.models import Chat, ChatMember, Message, RefreshToken, User
from app.db.session import SessionLocal


async def main() -> int:
    args = parse_args()
    async with SessionLocal() as session:
        user = await find_user(session, email=args.email, user_id=args.user_id)
        if user is None:
            print("User not found")
            return 1

        summary = await build_summary(session, user.id)
        print(f"User: {user.display_name} <{user.email}>")
        print(f"Id: {user.id}")
        print(f"Created chats: {summary['created_chats']}")
        print(f"Memberships: {summary['memberships']}")
        print(f"Sent messages: {summary['messages']}")
        print(f"Refresh tokens: {summary['refresh_tokens']}")

        if not args.yes:
            print("Add --yes to delete this user")
            return 0

        await session.delete(user)
        await session.commit()
        print("User deleted")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Delete a user from the messenger backend database")
    parser.add_argument("--email", help="User email")
    parser.add_argument("--id", dest="user_id", help="User id")
    parser.add_argument("--yes", action="store_true", help="Actually delete the user")
    args = parser.parse_args()
    if bool(args.email) == bool(args.user_id):
        parser.error("Provide exactly one of --email or --id")
    return args


async def find_user(session, email: str | None, user_id: str | None) -> User | None:
    if email is not None:
        result = await session.execute(select(User).where(func.lower(User.email) == email.lower()))
        return result.scalar_one_or_none()
    result = await session.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()


async def build_summary(session, user_id: str) -> dict[str, int]:
    return {
        "created_chats": await count_rows(session, select(func.count(Chat.id)).where(Chat.created_by_id == user_id)),
        "memberships": await count_rows(session, select(func.count(ChatMember.id)).where(ChatMember.user_id == user_id)),
        "messages": await count_rows(session, select(func.count(Message.id)).where(Message.sender_id == user_id)),
        "refresh_tokens": await count_rows(session, select(func.count(RefreshToken.id)).where(RefreshToken.user_id == user_id)),
    }


async def count_rows(session, statement) -> int:
    result = await session.execute(statement)
    return int(result.scalar_one() or 0)


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
