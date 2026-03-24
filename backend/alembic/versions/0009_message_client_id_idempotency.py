"""add message client id idempotency

Revision ID: 0009_message_client_id_idempotency
Revises: 0008_fix_system_user_email
Create Date: 2026-03-24
"""

from alembic import op
import sqlalchemy as sa


revision = "0009_message_client_id_idempotency"
down_revision = "0008_fix_system_user_email"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("messages", sa.Column("client_message_id", sa.String(length=128), nullable=True))
    op.create_unique_constraint(
        "uq_messages_client_message",
        "messages",
        ["chat_id", "sender_id", "client_message_id"],
    )


def downgrade() -> None:
    op.drop_constraint("uq_messages_client_message", "messages", type_="unique")
    op.drop_column("messages", "client_message_id")
