"""add message kind

Revision ID: 0005_message_kind
Revises: 0004_chat_member_notifications_enabled
Create Date: 2026-03-20
"""

from alembic import op
import sqlalchemy as sa


revision = "0005_message_kind"
down_revision = "0004_chat_member_notifications_enabled"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "messages",
        sa.Column("kind", sa.String(length=16), nullable=False, server_default="user"),
    )
    op.alter_column("messages", "kind", server_default=None)


def downgrade() -> None:
    op.drop_column("messages", "kind")
