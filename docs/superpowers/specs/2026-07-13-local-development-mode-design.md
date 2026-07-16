# Local Development Mode Design

## Goal

Allow the application to run on Windows without WSL, Docker, PostgreSQL,
Redis, or MinIO while preserving the existing production deployment path.

## Scope

- Add an explicit local development mode selected through environment
  configuration.
- Use SQLite for application data in local mode.
- Create the SQLite schema automatically during application startup.
- Keep uploaded avatars and generated local files under `backend/uploads`.
- Treat Redis and MinIO as disabled optional services in local mode.
- Preserve PostgreSQL, Redis, MinIO, and Docker Compose behavior outside local
  mode.

## Configuration

`APP_MODE` controls the runtime profile:

- `local`: SQLite database, local file storage, Redis disabled, MinIO disabled.
- `production`: PostgreSQL database and external service settings from the
  existing environment variables.

The database URL is resolved as follows:

1. `DATABASE_URL`, when explicitly configured.
2. `sqlite:///./data/local.db` in local mode.
3. The current PostgreSQL URL assembled from `DB_HOST`, `DB_PORT`, `DB_NAME`,
   `DB_USER`, and `DB_PASSWORD` in production mode.

`REDIS_ENABLED` and `MINIO_ENABLED` default to `false` in local mode and
`true` in production mode, but remain explicitly configurable.

## Database Lifecycle

The SQLAlchemy engine uses SQLite-specific `check_same_thread=false` settings
only for SQLite URLs. Local mode imports all ORM models and calls
`Base.metadata.create_all()` during FastAPI startup. Production mode continues
to rely on Alembic and does not auto-create tables.

## Storage Lifecycle

Existing avatar uploads already use `backend/uploads`. Local mode skips MinIO
bucket initialization. Production mode keeps the current MinIO client and
startup initialization.

## Health Reporting

The detailed health endpoint always checks the configured database. Redis and
MinIO checks report `disabled` when their feature flags are false. Disabled
optional services do not make the aggregate health status degraded.

## Error Handling

- SQLite parent directories are created before the engine is used.
- Database initialization errors fail application startup because business
  endpoints require a working database.
- External service failures remain visible in detailed health output when the
  services are enabled.

## Testing

- Settings tests cover local defaults, production defaults, and explicit URL
  overrides.
- Database tests cover SQLite engine options and local schema initialization.
- Health tests cover disabled optional services without network calls.
- Existing authentication, training utility, and frontend tests must remain
  green.

## Non-Goals

- Emulating pgvector features in SQLite.
- Replacing production migrations with automatic schema creation.
- Providing a native Windows Redis or MinIO installer.
- Changing Docker Compose deployment behavior.
