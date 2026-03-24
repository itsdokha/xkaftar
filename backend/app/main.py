from contextlib import asynccontextmanager
import logging
from time import perf_counter

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles

from app.api.router import api_router
from app.core.logging import configure_logging
from app.core.settings import get_settings
from app.db.session import initialize_database
from app.services.storage import StorageService


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger = logging.getLogger("app.startup")
    logger.info("Application startup started")
    try:
        await initialize_database()
    except Exception:
        logger.exception("Application startup failed")
        raise
    logger.info("Application startup completed")
    yield
    logger.info("Application shutdown completed")


settings = get_settings()
configure_logging(settings.log_level)
logger = logging.getLogger("app.main")
StorageService().ensure_directories()
app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allow_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(api_router)
app.mount("/media", StaticFiles(directory=settings.media_root_path), name="media")


@app.middleware("http")
async def log_requests(request: Request, call_next) -> Response:
    started_at = perf_counter()
    client_host = request.client.host if request.client else "-"
    logger.info("HTTP request started method=%s path=%s client=%s", request.method, request.url.path, client_host)
    try:
        response = await call_next(request)
    except Exception:
        logger.exception("HTTP request failed method=%s path=%s client=%s", request.method, request.url.path, client_host)
        raise
    duration_ms = (perf_counter() - started_at) * 1000
    logger.info(
        "HTTP request completed method=%s path=%s status=%s duration_ms=%.2f client=%s",
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
        client_host,
    )
    return response


@app.get("/health")
async def healthcheck() -> dict[str, str]:
    logger.info("Healthcheck requested")
    return {"status": "ok", "environment": settings.app_env}
