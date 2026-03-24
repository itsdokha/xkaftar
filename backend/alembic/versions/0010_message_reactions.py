"""message_reactions

Revision ID: 0010
Revises: 0009
Create Date: 2026-03-25
"""

from alembic import op
import sqlalchemy as sa

revision = "0010_message_reactions"
down_revision = "0009_message_client_id_idempotency"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "message_reactions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("message_id", sa.String(36), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("emoji", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("message_id", "user_id", "emoji", name="uq_message_reaction"),
    )


def downgrade() -> None:
    op.drop_table("message_reactions")
