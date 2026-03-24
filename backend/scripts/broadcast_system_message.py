import argparse
import asyncio
from pathlib import Path

from app.core.settings import get_settings
from app.db.session import SessionLocal
from app.db.repositories import ChatRepository, MessageRepository, UserRepository
from app.domain.enums import ChatRole, ChatType


async def main() -> int:
    args = parse_args()
    body = resolve_body(args)

    async with SessionLocal() as session:
        settings = get_settings()
        users = UserRepository(session)
        chats = ChatRepository(session)
        messages = MessageRepository(session)

        system_user = await users.get_by_email(settings.system_user_email)
        if system_user is None:
            print(f"System user not found: {settings.system_user_email}")
            print("Register any user first or create the system account before broadcasting")
            return 1

        recipients = [user for user in await users.list_all(include_system=False) if user.id != system_user.id]
        created_chat_count = 0
        existing_chat_count = 0

        for user in recipients:
            direct_chat = await chats.find_direct_between(system_user.id, user.id)
            if direct_chat is None:
                created_chat_count += 1
            else:
                existing_chat_count += 1

        print(f"System user: {system_user.display_name} <{system_user.email}>")
        print(f"Recipients: {len(recipients)}")
        print(f"Existing direct chats: {existing_chat_count}")
        print(f"Direct chats to create: {created_chat_count}")
        print(f"Message length: {len(body)}")
        print("Preview:")
        print(body)

        if not args.yes:
            print("Add --yes to send this broadcast")
            return 0

        sent_count = 0
        created_now = 0
        for user in recipients:
            direct_chat = await chats.find_direct_between(system_user.id, user.id)
            if direct_chat is None:
                direct_chat = await chats.create_chat(ChatType.DIRECT, system_user.id)
                await chats.add_member(direct_chat.id, system_user.id, ChatRole.OWNER)
                await chats.add_member(direct_chat.id, user.id, ChatRole.MEMBER)
                created_now += 1
            await messages.create(
                chat_id=direct_chat.id,
                sender_id=system_user.id,
                body=body,
            )
            await chats.touch(direct_chat)
            await chats.mark_read(direct_chat.id, system_user.id)
            sent_count += 1

        await session.commit()
        print(f"Broadcast sent to {sent_count} users")
        print(f"Direct chats created: {created_now}")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a direct-message broadcast from the Kaftar system account to all users"
    )
    parser.add_argument("--message", help="Broadcast message text")
    parser.add_argument("--message-file", help="Path to a UTF-8 text file with the broadcast message")
    parser.add_argument("--yes", action="store_true", help="Actually send the broadcast")
    args = parser.parse_args()
    if bool(args.message) == bool(args.message_file):
        parser.error("Provide exactly one of --message or --message-file")
    return args


def resolve_body(args: argparse.Namespace) -> str:
    if args.message:
        body = args.message
    else:
        body = Path(args.message_file).read_text(encoding="utf-8")
    body = body.strip()
    if not body:
        raise SystemExit("Broadcast message cannot be empty")
    if len(body) > 4000:
        raise SystemExit("Broadcast message must be at most 4000 characters long")
    return body


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
