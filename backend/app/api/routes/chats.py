import logging
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, status

from app.api.dependencies import DbSession, get_current_user
from app.schemas.chat import (
    AddMemberRequest,
    ChatRead,
    ChatNotificationSettingsUpdate,
    DirectChatCreate,
    GroupChatRenameRequest,
    GroupChatCreate,
    MessageCreate,
    MessagePageRead,
    MessageRead,
    VoiceJoinRead,
    VoiceStateRead,
)
from app.services.chats import ChatService
from app.services.exceptions import AuthorizationError, ConflictError, NotFoundError
from app.services.push_notifications import PushNotificationService
from app.services.realtime import connection_manager
from app.services.storage import StorageService
from app.services.voice import VoiceService


router = APIRouter()
logger = logging.getLogger("app.api.chats")


async def _broadcast_chat_state(service: ChatService, chat_id: str, user_ids: list[str], event_name: str) -> None:
    for user_id in user_ids:
        chat = await service.get_chat(chat_id, user_id)
        await connection_manager.send_to_user(
            user_id,
            {"event": event_name, "data": chat.model_dump(mode="json")},
        )


async def _broadcast_voice_state(service: VoiceService, chat_id: str) -> VoiceStateRead:
    state = await service.get_state_for_chat(chat_id)
    user_ids = await service.voice_member_user_ids(chat_id)
    await connection_manager.broadcast(
        user_ids,
        {"event": "voice_state_updated", "data": state.model_dump(mode="json")},
    )
    return state


@router.get("", response_model=list[ChatRead])
async def list_chats(
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> list[ChatRead]:
    chats = await ChatService(session).list_chats(current_user.id)
    logger.info("Chats listed user_id=%s count=%s", current_user.id, len(chats))
    return chats


@router.post("/direct", response_model=ChatRead, status_code=status.HTTP_201_CREATED)
async def create_direct_chat(
    payload: DirectChatCreate,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    try:
        chat = await service.create_direct_chat(current_user.id, payload.email)
    except NotFoundError as error:
        logger.warning("Direct chat creation failed user_id=%s email=%s detail=%s", current_user.id, payload.email, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Direct chat creation conflict user_id=%s email=%s detail=%s", current_user.id, payload.email, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Direct chat created user_id=%s chat_id=%s email=%s", current_user.id, chat.id, payload.email)
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    return chat


@router.post("/{chat_id}/voice/join", response_model=VoiceJoinRead)
async def join_voice_room(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> VoiceJoinRead:
    service = VoiceService(session)
    try:
        result = await service.create_join(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Voice join failed chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Voice join forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Voice join conflict chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Voice join token issued chat_id=%s user_id=%s", chat_id, current_user.id)
    return result


@router.get("/{chat_id}/voice/state", response_model=VoiceStateRead)
async def get_voice_state(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> VoiceStateRead:
    service = VoiceService(session)
    try:
        state = await service.get_state(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Voice state failed chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Voice state forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Voice state conflict chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Voice state returned chat_id=%s user_id=%s participants=%s", chat_id, current_user.id, len(state.participants))
    return state


@router.post("/{chat_id}/voice/participants/{user_id}/mute", response_model=VoiceStateRead)
async def mute_voice_participant(
    chat_id: str,
    user_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> VoiceStateRead:
    service = VoiceService(session)
    try:
        await service.mute_participant(chat_id, current_user.id, user_id)
        state = await _broadcast_voice_state(service, chat_id)
    except NotFoundError as error:
        logger.warning(
            "Voice mute failed chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning(
            "Voice mute forbidden chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning(
            "Voice mute conflict chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    await connection_manager.send_to_user(
        user_id,
        {
            "event": "voice_moderation_notice",
            "data": {
                "chat_id": chat_id,
                "action": "muted",
                "actor_display_name": current_user.display_name,
            },
        },
    )
    logger.info("Voice mute stored chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user.id, user_id)
    return state


@router.delete("/{chat_id}/voice/participants/{user_id}", response_model=VoiceStateRead)
async def kick_voice_participant(
    chat_id: str,
    user_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> VoiceStateRead:
    service = VoiceService(session)
    try:
        await service.kick_participant(chat_id, current_user.id, user_id)
        state = await _broadcast_voice_state(service, chat_id)
    except NotFoundError as error:
        logger.warning(
            "Voice kick failed chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning(
            "Voice kick forbidden chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning(
            "Voice kick conflict chat_id=%s actor_id=%s target_user_id=%s detail=%s",
            chat_id,
            current_user.id,
            user_id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    await connection_manager.send_to_user(
        user_id,
        {
            "event": "voice_moderation_notice",
            "data": {
                "chat_id": chat_id,
                "action": "kicked",
                "actor_display_name": current_user.display_name,
            },
        },
    )
    logger.info("Voice kick stored chat_id=%s actor_id=%s target_user_id=%s", chat_id, current_user.id, user_id)
    return state


@router.post("/group", response_model=ChatRead, status_code=status.HTTP_201_CREATED)
async def create_group_chat(
    payload: GroupChatCreate,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    chat = await service.create_group_chat(current_user.id, payload.title, list(payload.member_emails))
    logger.info(
        "Group chat created user_id=%s chat_id=%s title=%s members=%s",
        current_user.id,
        chat.id,
        payload.title,
        len(chat.members),
    )
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    return chat


@router.post("/{chat_id}/rename", response_model=ChatRead)
async def rename_group_chat(
    chat_id: str,
    payload: GroupChatRenameRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    try:
        chat, system_message = await service.rename_group(chat_id, current_user.id, payload.title)
    except NotFoundError as error:
        logger.warning("Group rename failed chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Group rename forbidden chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Group rename conflict chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Group renamed chat_id=%s actor_id=%s title=%s", chat_id, current_user.id, payload.title)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_created", "data": system_message.model_dump(mode="json")},
    )
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    return chat


@router.post("/{chat_id}/notifications", response_model=ChatRead)
async def update_chat_notifications(
    chat_id: str,
    payload: ChatNotificationSettingsUpdate,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    try:
        chat = await service.update_notifications_enabled(chat_id, current_user.id, payload.enabled)
    except NotFoundError as error:
        logger.warning(
            "Notifications update failed chat_id=%s actor_id=%s detail=%s",
            chat_id,
            current_user.id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning(
            "Notifications update forbidden chat_id=%s actor_id=%s detail=%s",
            chat_id,
            current_user.id,
            error,
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    logger.info(
        "Notifications updated chat_id=%s actor_id=%s enabled=%s",
        chat_id,
        current_user.id,
        payload.enabled,
    )
    await connection_manager.send_to_user(
        current_user.id,
        {"event": "chat_updated", "data": chat.model_dump(mode="json")},
    )
    return chat


@router.post("/{chat_id}/leave")
async def leave_group_chat(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> dict[str, bool]:
    service = ChatService(session)
    try:
        member_user_ids, system_message, chat_title = await service.leave_group(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Leave group failed chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Leave group forbidden chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Leave group conflict chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    remaining_user_ids = [user_id for user_id in member_user_ids if user_id != current_user.id]
    if remaining_user_ids:
        await connection_manager.broadcast(
            remaining_user_ids,
            {"event": "message_created", "data": system_message.model_dump(mode="json")},
        )
        await _broadcast_chat_state(service, chat_id, remaining_user_ids, "chat_updated")
    await connection_manager.send_to_user(
        current_user.id,
        {
            "event": "chat_removed",
            "data": {
                "chat_id": chat_id,
                "reason": "left",
                "title": chat_title,
            },
        },
    )
    return {"removed": True}


@router.delete("/{chat_id}")
async def delete_group_chat(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> dict[str, bool]:
    service = ChatService(session)
    try:
        member_user_ids, chat_title = await service.delete_group(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Delete group failed chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Delete group forbidden chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Delete group conflict chat_id=%s actor_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    await connection_manager.broadcast(
        member_user_ids,
        {
            "event": "chat_removed",
            "data": {
                "chat_id": chat_id,
                "reason": "deleted",
                "title": chat_title,
            },
        },
    )
    return {"removed": True}


@router.get("/{chat_id}", response_model=ChatRead)
async def get_chat(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    try:
        chat = await ChatService(session).get_chat(chat_id, current_user.id)
        logger.info("Chat fetched chat_id=%s user_id=%s", chat_id, current_user.id)
        return chat
    except NotFoundError as error:
        logger.warning("Chat fetch not found chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Chat fetch forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error


@router.post("/{chat_id}/members", response_model=ChatRead)
async def add_member(
    chat_id: str,
    payload: AddMemberRequest,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    try:
        chat, system_message = await service.add_member(chat_id, current_user.id, payload.email)
    except NotFoundError as error:
        logger.warning("Add member failed chat_id=%s actor_id=%s email=%s detail=%s", chat_id, current_user.id, payload.email, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Add member forbidden chat_id=%s actor_id=%s email=%s detail=%s", chat_id, current_user.id, payload.email, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Add member conflict chat_id=%s actor_id=%s email=%s detail=%s", chat_id, current_user.id, payload.email, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Member added chat_id=%s actor_id=%s email=%s", chat_id, current_user.id, payload.email)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_created", "data": system_message.model_dump(mode="json")},
    )
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "member_added")
    return chat


@router.delete("/{chat_id}/members/{user_id}")
async def remove_member(
    chat_id: str,
    user_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> dict[str, bool]:
    service = ChatService(session)
    try:
        member_user_ids, system_message, chat_title, _removed_name = await service.remove_member_from_group(
            chat_id,
            current_user.id,
            user_id,
        )
    except NotFoundError as error:
        logger.warning("Remove member failed chat_id=%s actor_id=%s target_user_id=%s detail=%s", chat_id, current_user.id, user_id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Remove member forbidden chat_id=%s actor_id=%s target_user_id=%s detail=%s", chat_id, current_user.id, user_id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Remove member conflict chat_id=%s actor_id=%s target_user_id=%s detail=%s", chat_id, current_user.id, user_id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    remaining_user_ids = [member_id for member_id in member_user_ids if member_id != user_id]
    if remaining_user_ids:
        await connection_manager.broadcast(
            remaining_user_ids,
            {"event": "message_created", "data": system_message.model_dump(mode="json")},
        )
        await _broadcast_chat_state(service, chat_id, remaining_user_ids, "chat_updated")
    await connection_manager.send_to_user(
        user_id,
        {
            "event": "chat_removed",
            "data": {
                "chat_id": chat_id,
                "reason": "removed",
                "title": chat_title,
            },
        },
    )
    return {"removed": True}


@router.get("/{chat_id}/messages", response_model=MessagePageRead)
async def list_messages(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    limit: int = Query(default=50, ge=1, le=100),
    before_message_id: str | None = Query(default=None),
) -> MessagePageRead:
    service = ChatService(session)
    try:
        messages, read_state_changed = await service.list_messages(
            chat_id,
            current_user.id,
            limit=limit,
            before_message_id=before_message_id,
        )
        if read_state_changed:
            chat = await service.get_chat(chat_id, current_user.id)
            await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
            await connection_manager.broadcast(
                [member.user.id for member in chat.members],
                {"event": "read_state_updated", "data": {"chat_id": chat.id}},
            )
        logger.info(
            "Messages listed chat_id=%s user_id=%s count=%s limit=%s before_message_id=%s read_state_changed=%s",
            chat_id,
            current_user.id,
            len(messages.items),
            limit,
            before_message_id,
            read_state_changed,
        )
        return messages
    except AuthorizationError as error:
        logger.warning("Messages list forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error


@router.post("/{chat_id}/read", response_model=ChatRead)
async def mark_chat_read(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> ChatRead:
    service = ChatService(session)
    try:
        chat, read_state_changed = await service.mark_read(chat_id, current_user.id)
        if read_state_changed:
            await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
            await connection_manager.broadcast(
                [member.user.id for member in chat.members],
                {"event": "read_state_updated", "data": {"chat_id": chat.id}},
            )
        return chat
    except AuthorizationError as error:
        logger.warning("Read mark forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except NotFoundError as error:
        logger.warning("Read mark not found chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error


@router.post("/{chat_id}/messages", response_model=MessageRead, status_code=status.HTTP_201_CREATED)
async def create_message(
    chat_id: str,
    payload: MessageCreate,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
) -> MessageRead:
    service = ChatService(session)
    try:
        message = await service.create_message(
            chat_id,
            current_user.id,
            payload.body,
            reply_to_message_id=payload.reply_to_message_id,
            client_message_id=payload.client_message_id,
        )
        chat = await service.get_chat(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Message creation failed chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Message creation forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    logger.info("Message created chat_id=%s user_id=%s message_id=%s", chat_id, current_user.id, message.id)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_created", "data": message.model_dump(mode="json")},
    )
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    try:
        await PushNotificationService(session).send_message_notifications(
            chat=chat,
            message=message,
            sender_user_id=current_user.id,
        )
    except Exception:
        logger.exception("Push notifications failed chat_id=%s message_id=%s", chat_id, message.id)
    return message


@router.post("/{chat_id}/images", response_model=MessageRead, status_code=status.HTTP_201_CREATED)
async def create_image_message(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    file: UploadFile = File(...),
    body: str = Form(default=""),
    reply_to_message_id: str | None = Form(default=None),
    client_message_id: str | None = Form(default=None),
) -> MessageRead:
    service = ChatService(session)
    try:
        image_url = await StorageService().save_message_image(file, current_user.id)
        message = await service.create_message(
            chat_id,
            current_user.id,
            body,
            image_url=image_url,
            reply_to_message_id=reply_to_message_id,
            client_message_id=client_message_id,
        )
        chat = await service.get_chat(chat_id, current_user.id)
    except NotFoundError as error:
        logger.warning("Image message failed chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Image message forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Image message conflict chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Image message created chat_id=%s user_id=%s message_id=%s filename=%s", chat_id, current_user.id, message.id, file.filename)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_created", "data": message.model_dump(mode="json")},
    )
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    try:
        await PushNotificationService(session).send_message_notifications(
            chat=chat,
            message=message,
            sender_user_id=current_user.id,
        )
    except Exception:
        logger.exception("Push notifications failed chat_id=%s message_id=%s", chat_id, message.id)
    return message


@router.post("/{chat_id}/icon", response_model=ChatRead)
async def update_group_icon(
    chat_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    file: UploadFile = File(...),
) -> ChatRead:
    service = ChatService(session)
    try:
        icon_url = await StorageService().save_group_icon(file, chat_id)
        chat = await service.update_group_icon(chat_id, current_user.id, icon_url)
    except NotFoundError as error:
        logger.warning("Group icon update failed chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        logger.warning("Group icon update forbidden chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except ConflictError as error:
        logger.warning("Group icon update conflict chat_id=%s user_id=%s detail=%s", chat_id, current_user.id, error)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    logger.info("Group icon updated chat_id=%s user_id=%s filename=%s", chat_id, current_user.id, file.filename)
    await _broadcast_chat_state(service, chat.id, [member.user.id for member in chat.members], "chat_updated")
    return chat


@router.post("/{chat_id}/messages/{message_id}/reactions", response_model=MessageRead)
async def add_reaction(
    chat_id: str,
    message_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    emoji: str = Query(..., max_length=32),
) -> MessageRead:
    service = ChatService(session)
    try:
        message = await service.add_reaction(message_id, current_user.id, emoji)
    except NotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except AuthorizationError as error:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    logger.info("Reaction added chat_id=%s message_id=%s user_id=%s emoji=%s", chat_id, message_id, current_user.id, emoji)
    chat = await service.get_chat(chat_id, current_user.id)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_updated", "data": message.model_dump(mode="json")},
    )
    return message


@router.delete("/{chat_id}/messages/{message_id}/reactions", response_model=MessageRead)
async def remove_reaction(
    chat_id: str,
    message_id: str,
    session: DbSession,
    current_user: Annotated[object, Depends(get_current_user)],
    emoji: str = Query(..., max_length=32),
) -> MessageRead:
    service = ChatService(session)
    try:
        message = await service.remove_reaction(message_id, current_user.id, emoji)
    except NotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    logger.info("Reaction removed chat_id=%s message_id=%s user_id=%s emoji=%s", chat_id, message_id, current_user.id, emoji)
    chat = await service.get_chat(chat_id, current_user.id)
    await connection_manager.broadcast(
        [member.user.id for member in chat.members],
        {"event": "message_updated", "data": message.model_dump(mode="json")},
    )
    return message
