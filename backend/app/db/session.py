import asyncio
import logging
from pathlib import Path
from collections.abc import AsyncIterator

from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.settings import get_settings
from app.db.repositories import ChatRepository, UserRepository
from app.domain.enums import ChatRole
from app.services.storage import StorageService


settings = get_settings()
logger = logging.getLogger("app.db.session")
engine = create_async_engine(settings.database_url, future=True, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_db_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


async def initialize_database() -> None:
    logger.info("Running database migrations")
    config = _build_alembic_config()
    logger.debug("Alembic config prepared script_location=%s", config.get_main_option("script_location"))
    try:
        await asyncio.to_thread(command.upgrade, config, "head")
    except Exception:
        logger.exception("Database migrations failed")
        raise
    logger.info("Database migrations completed")
    # Warm up the connection pool so the first user request is fast
    from sqlalchemy import text
    async with SessionLocal() as session:
        await session.execute(text("SELECT 1"))
    logger.info("Database connection pool warmed up")
    StorageService().ensure_directories()
    logger.info("Storage directories ensured at %s", settings.media_root_path)
    await _sync_all_monkeys_groups()


def _build_alembic_config() -> Config:
    project_root = Path(__file__).resolve().parents[2]
    config = Config(str(project_root / "alembic.ini"))
    config.set_main_option("script_location", str(project_root / "alembic"))
    config.set_main_option("sqlalchemy.url", settings.database_url)
    return config


async def _sync_all_monkeys_groups() -> None:
    async with SessionLocal() as session:
        chats = ChatRepository(session)
        users = UserRepository(session)
        group_ids = await chats.list_group_ids_by_title("ALL MONKEYS")
        if not group_ids:
            logger.info("ALL MONKEYS sync skipped because no target groups were found")
            return
        user_ids = await users.list_all_ids()
        changed = False
        added_members = 0
        for group_id in group_ids:
            member_ids = set(await chats.list_member_user_ids(group_id))
            for user_id in user_ids:
                if user_id not in member_ids:
                    await chats.add_member(group_id, user_id, ChatRole.MEMBER)
                    changed = True
                    added_members += 1
        if changed:
            await session.commit()
            logger.info("ALL MONKEYS sync completed groups=%s added_members=%s", len(group_ids), added_members)
            return
        logger.info("ALL MONKEYS sync completed with no changes groups=%s", len(group_ids))

