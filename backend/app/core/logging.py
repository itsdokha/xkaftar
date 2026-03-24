import logging
from logging.config import dictConfig


def configure_logging(log_level: str) -> None:
    level = log_level.upper()
    dictConfig(
        {
            "version": 1,
            "disable_existing_loggers": False,
            "formatters": {
                "default": {
                    "format": "%(asctime)s | %(levelname)s | %(name)s | %(message)s",
                },
            },
            "handlers": {
                "default": {
                    "class": "logging.StreamHandler",
                    "formatter": "default",
                },
            },
            "root": {
                "handlers": ["default"],
                "level": level,
            },
            "loggers": {
                "uvicorn": {"level": level},
                "uvicorn.error": {"level": level},
                "uvicorn.access": {"level": level},
                "sqlalchemy.engine": {"level": "INFO" if level == "DEBUG" else "WARNING"},
                "alembic": {"level": level},
            },
        }
    )
    logging.getLogger(__name__).info("Logging configured with level=%s", level)
