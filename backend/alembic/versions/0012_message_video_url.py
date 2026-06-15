"""add message video url

Revision ID: 0012_message_video_url
Revises: 0011_single_reaction_per_user
Create Date: 2026-04-01
"""

from alembic import op
import sqlalchemy as sa


revision = "0012_message_video_url"
down_revision = "0011_single_reaction_per_user"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("messages", sa.Column("video_url", sa.String(length=1024), nullable=True))


def downgrade() -> None:
    op.drop_column("messages", "video_url")
