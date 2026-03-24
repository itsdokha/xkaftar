from alembic import op
import sqlalchemy as sa


revision = "0002_push_device_tokens"
down_revision = "0001_initial_schema"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "push_device_tokens",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("token", sa.String(length=512), nullable=False),
        sa.Column("platform", sa.String(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_push_device_tokens_token"), "push_device_tokens", ["token"], unique=True)
    op.create_index(op.f("ix_push_device_tokens_user_id"), "push_device_tokens", ["user_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_push_device_tokens_user_id"), table_name="push_device_tokens")
    op.drop_index(op.f("ix_push_device_tokens_token"), table_name="push_device_tokens")
    op.drop_table("push_device_tokens")
