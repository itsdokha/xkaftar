"""single_reaction_per_user

Revision ID: 0011
Revises: 0010
Create Date: 2026-03-25
"""

from alembic import op
import sqlalchemy as sa

revision = "0011_single_reaction_per_user"
down_revision = "0010_message_reactions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DELETE FROM message_reactions
        WHERE id IN (
            SELECT id
            FROM (
                SELECT
                    id,
                    ROW_NUMBER() OVER (
                        PARTITION BY message_id, user_id
                        ORDER BY created_at DESC, id DESC
                    ) AS duplicate_rank
                FROM message_reactions
            ) ranked
            WHERE ranked.duplicate_rank > 1
        )
        """
    )
    with op.batch_alter_table("message_reactions") as batch_op:
        batch_op.drop_constraint("uq_message_reaction", type_="unique")
        batch_op.create_unique_constraint("uq_message_reaction_user", ["message_id", "user_id"])


def downgrade() -> None:
    with op.batch_alter_table("message_reactions") as batch_op:
        batch_op.drop_constraint("uq_message_reaction_user", type_="unique")
        batch_op.create_unique_constraint("uq_message_reaction", ["message_id", "user_id", "emoji"])
