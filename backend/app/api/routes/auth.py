import logging

from fastapi import APIRouter, HTTPException, status

from app.api.dependencies import DbSession
from app.schemas.auth import AuthResponse, LoginRequest, RefreshRequest, RegisterRequest, TokenPair
from app.services.auth import AuthService
from app.services.exceptions import AuthenticationError, ConflictError


router = APIRouter()
logger = logging.getLogger("app.api.auth")


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, session: DbSession) -> AuthResponse:
    service = AuthService(session)
    try:
        result = await service.register(payload.email, payload.password, payload.display_name)
        logger.info("User registered email=%s user_id=%s", payload.email, result.user.id)
        return result
    except ConflictError as error:
        logger.warning("User registration conflict email=%s detail=%s", payload.email, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error


@router.post("/login", response_model=AuthResponse)
async def login(payload: LoginRequest, session: DbSession) -> AuthResponse:
    service = AuthService(session)
    try:
        result = await service.login(payload.email, payload.password)
        logger.info("User logged in email=%s user_id=%s", payload.email, result.user.id)
        return result
    except AuthenticationError as error:
        logger.warning("User login failed email=%s detail=%s", payload.email, error)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(error)) from error


@router.post("/refresh", response_model=TokenPair)
async def refresh(payload: RefreshRequest, session: DbSession) -> TokenPair:
    service = AuthService(session)
    try:
        tokens = await service.refresh(payload.refresh_token)
        logger.info("Refresh token accepted")
        return tokens
    except AuthenticationError as error:
        logger.warning("Refresh token rejected detail=%s", error)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(error)) from error
