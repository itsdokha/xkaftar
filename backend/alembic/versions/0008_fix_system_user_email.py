"""fix system user email

Revision ID: 0008_fix_system_user_email
Revises: 0007_normalize_message_kind_values
Create Date: 2026-03-20
"""

from alembic import op


revision = "0008_fix_system_user_email"
down_revision = "0007_normalize_message_kind_values"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        DECLARE
            legacy_user_id VARCHAR(36);
            target_user_id VARCHAR(36);
        BEGIN
            SELECT id INTO legacy_user_id
            FROM users
            WHERE LOWER(email) = 'system@kaftar.local'
            LIMIT 1;

            IF legacy_user_id IS NULL THEN
                RETURN;
            END IF;

            SELECT id INTO target_user_id
            FROM users
            WHERE LOWER(email) = 'system@kaftar.kuchizu.com'
            LIMIT 1;

            IF target_user_id IS NULL THEN
                UPDATE users
                SET email = 'system@kaftar.kuchizu.com'
                WHERE id = legacy_user_id;
                RETURN;
            END IF;

            IF target_user_id = legacy_user_id THEN
                RETURN;
            END IF;

            UPDATE refresh_tokens
            SET user_id = target_user_id
            WHERE user_id = legacy_user_id;

            UPDATE push_device_tokens
            SET user_id = target_user_id
            WHERE user_id = legacy_user_id;

            UPDATE chats
            SET created_by_id = target_user_id
            WHERE created_by_id = legacy_user_id;

            UPDATE messages
            SET sender_id = target_user_id
            WHERE sender_id = legacy_user_id;

            DELETE FROM chat_members legacy_member
            USING chat_members target_member
            WHERE legacy_member.user_id = legacy_user_id
              AND target_member.user_id = target_user_id
              AND target_member.chat_id = legacy_member.chat_id;

            UPDATE chat_members
            SET user_id = target_user_id
            WHERE user_id = legacy_user_id;

            DELETE FROM users
            WHERE id = legacy_user_id;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute(
        """
        UPDATE users
        SET email = 'system@kaftar.local'
        WHERE LOWER(email) = 'system@kaftar.kuchizu.com' AND display_name = 'Kaftar'
        """
    )
