"""add user bio

Revision ID: 0003_user_bio
Revises: 0002_push_device_tokens
Create Date: 2026-03-19 00:00:00
"""

from alembic import op
import sqlalchemy as sa


revision = "0003_user_bio"
down_revision = "0002_push_device_tokens"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("bio", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "bio")
