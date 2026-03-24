"""add user sessions revoked at

Revision ID: 0006_user_sessions_revoked_at
Revises: 0005_message_kind
Create Date: 2026-03-20
"""

from alembic import op
import sqlalchemy as sa


revision = "0006_user_sessions_revoked_at"
down_revision = "0005_message_kind"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("sessions_revoked_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "sessions_revoked_at")
