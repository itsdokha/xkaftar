"""add chat member notifications toggle

Revision ID: 0004_chat_member_notifications_enabled
Revises: 0003_user_bio
Create Date: 2026-03-20
"""

from alembic import op
import sqlalchemy as sa


revision = "0004_chat_member_notifications_enabled"
down_revision = "0003_user_bio"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "chat_members",
        sa.Column("notifications_enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.alter_column("chat_members", "notifications_enabled", server_default=None)


def downgrade() -> None:
    op.drop_column("chat_members", "notifications_enabled")
