"""normalize message kind values

Revision ID: 0007_normalize_message_kind_values
Revises: 0006_user_sessions_revoked_at
Create Date: 2026-03-20
"""

from alembic import op


revision = "0007_normalize_message_kind_values"
down_revision = "0006_user_sessions_revoked_at"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE messages SET kind = LOWER(kind) WHERE kind IS NOT NULL")


def downgrade() -> None:
    op.execute("UPDATE messages SET kind = UPPER(kind) WHERE kind IS NOT NULL")
