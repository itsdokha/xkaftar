import argparse
import asyncio
import getpass

from sqlalchemy import delete, func, select

from app.core.security import hash_password
from app.db.models import RefreshToken, User
from app.db.session import SessionLocal


async def main() -> int:
    args = parse_args()
    password = resolve_password(args)

    async with SessionLocal() as session:
        user = await find_user(session, email=args.email, user_id=args.user_id)
        if user is None:
            print("User not found")
            return 1

        refresh_tokens_before = await count_refresh_tokens(session, user.id)
        print(f"User: {user.display_name} <{user.email}>")
        print(f"Id: {user.id}")
        print(f"Refresh tokens: {refresh_tokens_before}")

        if not args.yes:
            print("Add --yes to change this user's password")
            return 0

        user.password_hash = hash_password(password)
        revoke_count = 0
        if not args.keep_sessions:
            result = await session.execute(delete(RefreshToken).where(RefreshToken.user_id == user.id))
            revoke_count = int(result.rowcount or 0)
        await session.commit()

        print("Password updated")
        if args.keep_sessions:
            print("Refresh tokens kept")
        else:
            print(f"Refresh tokens revoked: {revoke_count}")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Change a user's password in the messenger backend database")
    parser.add_argument("--email", help="User email")
    parser.add_argument("--id", dest="user_id", help="User id")
    parser.add_argument("--password", help="New password. If omitted, prompt securely")
    parser.add_argument("--yes", action="store_true", help="Actually change the password")
    parser.add_argument(
        "--keep-sessions",
        action="store_true",
        help="Keep existing refresh tokens instead of revoking sessions",
    )
    args = parser.parse_args()
    if bool(args.email) == bool(args.user_id):
        parser.error("Provide exactly one of --email or --id")
    return args


def resolve_password(args: argparse.Namespace) -> str:
    if args.password:
        password = args.password
    else:
        first = getpass.getpass("New password: ")
        second = getpass.getpass("Repeat password: ")
        if first != second:
            raise SystemExit("Passwords do not match")
        password = first
    if len(password) < 6:
        raise SystemExit("Password must be at least 6 characters long")
    return password


async def find_user(session, email: str | None, user_id: str | None) -> User | None:
    if email is not None:
        result = await session.execute(select(User).where(func.lower(User.email) == email.lower()))
        return result.scalar_one_or_none()
    result = await session.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()


async def count_refresh_tokens(session, user_id: str) -> int:
    result = await session.execute(select(func.count(RefreshToken.id)).where(RefreshToken.user_id == user_id))
    return int(result.scalar_one() or 0)


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
