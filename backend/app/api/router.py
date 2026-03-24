from fastapi import APIRouter

from app.api.routes import admin, auth, chats, devices, integrations, users, utils, websocket


api_router = APIRouter()
api_router.include_router(auth.router, prefix="/auth", tags=["auth"])
api_router.include_router(admin.router, prefix="/admin", tags=["admin"])
api_router.include_router(users.router, prefix="/users", tags=["users"])
api_router.include_router(devices.router, prefix="/devices", tags=["devices"])
api_router.include_router(chats.router, prefix="/chats", tags=["chats"])
api_router.include_router(integrations.router, prefix="/integrations", tags=["integrations"])
api_router.include_router(utils.router, prefix="/utils", tags=["utils"])
api_router.include_router(websocket.router, tags=["ws"])
