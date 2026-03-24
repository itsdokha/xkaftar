# Contributing

## Workflow

- Create a separate branch for each change.
- Keep commits focused and small.
- Prefer fixing the root cause instead of patching symptoms.

## Project structure

- `backend/` contains the server, API, migrations, and scripts.
- `flutter-client/` contains the Flutter client for all supported platforms.

## Before committing

- Do not commit secrets.
- Do not commit local `.env` files, Firebase service accounts, or private keys.
- Keep generated build output out of git.
- If backend schema changes, add an Alembic migration.
- If API contracts change, update the Flutter client in the same change.

## Backend

- Keep business logic in `app/services/`.
- Keep database access in `app/db/repositories.py`.
- Add or update migrations in `backend/alembic/versions/` when needed.

## Flutter client

- Keep UI changes consistent across desktop, mobile, and web when applicable.
- Avoid hardcoding production secrets or environment-specific values.
- Put helper scripts in `flutter-client/scripts/`.

## Pull requests

- Describe what changed and why.
- Mention any migrations, env changes, or manual deployment steps.
- Include screenshots for visible UI changes when useful.
