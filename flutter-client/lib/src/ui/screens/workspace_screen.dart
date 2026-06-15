import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../models/chat.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../models/voice.dart';
import '../../state/app_controller.dart';
import '../widgets/cached_network_media.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/message_bubble.dart';
import '../widgets/triangle_video_recorder_sheet.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final messageController = TextEditingController();
  final scrollController = ScrollController();
  final messageFocusNode = FocusNode();
  MessageModel? replyTarget;
  String? lastSelectedChatId;
  int lastMessageCount = -1;
  String? lastTailMessageId;
  String? lastHeadMessageId;
  Timer? _bottomSettleTimer;
  bool _stickToBottom = true;
  bool _showScrollToBottom = false;
  int _lastNoticeId = 0;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_handleScrollChanged);
  }

  @override
  void dispose() {
    _bottomSettleTimer?.cancel();
    scrollController.removeListener(_handleScrollChanged);
    messageController.dispose();
    scrollController.dispose();
    messageFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final selectedChat = controller.selectedChat;
        final selectedMessages = controller.selectedMessages;
        final chatChanged = selectedChat?.id != lastSelectedChatId;
        final currentTailMessageId = selectedMessages.isEmpty ? null : selectedMessages.last.id;
        final currentHeadMessageId = selectedMessages.isEmpty ? null : selectedMessages.first.id;
        final tailChanged = currentTailMessageId != lastTailMessageId;
        final headChanged = currentHeadMessageId != lastHeadMessageId;
        final countChanged = selectedMessages.length != lastMessageCount;
        if (chatChanged) {
          replyTarget = null;
        }
        if (chatChanged || countChanged) {
          final olderMessagesLoaded = !chatChanged && headChanged && !tailChanged && countChanged;
          final prevMaxExtent = scrollController.hasClients ? scrollController.position.maxScrollExtent : 0.0;
          final prevOffset = scrollController.hasClients ? scrollController.offset : 0.0;
          lastSelectedChatId = selectedChat?.id;
          lastMessageCount = selectedMessages.length;
          lastTailMessageId = currentTailMessageId;
          lastHeadMessageId = currentHeadMessageId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            if (olderMessagesLoaded && scrollController.hasClients) {
              final newMaxExtent = scrollController.position.maxScrollExtent;
              final addedExtent = newMaxExtent - prevMaxExtent;
              if (addedExtent > 0) {
                scrollController.jumpTo(prevOffset + addedExtent);
              }
              return;
            }
            if (chatChanged || tailChanged) {
              _scheduleScrollToBottom(force: chatChanged);
            }
            if (chatChanged && selectedChat != null) {
              _focusComposer();
            }
          });
        }
        final width = MediaQuery.sizeOf(context).width;
        final compact = width < 960;
        final outerPadding = compact ? 4.0 : 10.0;
        final showSidebarOnly = compact && controller.selectedChat == null;
        final showChatOnly = compact && controller.selectedChat != null;
        if (controller.noticeId != _lastNoticeId && controller.latestNoticeMessage != null) {
          final noticeId = controller.noticeId;
          final noticeText = controller.latestNoticeMessage!;
          _lastNoticeId = noticeId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            final messenger = ScaffoldMessenger.of(context);
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  margin: const EdgeInsets.all(18),
                  backgroundColor: const Color(0xFF121821),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: const BorderSide(color: Color(0xFF2A3644)),
                  ),
                  content: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: Color(0xFF8FD1FF),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          noticeText,
                          style: const TextStyle(
                            color: Color(0xFFE6EDF5),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            controller.clearNotice();
          });
        }
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(outerPadding),
              child: Row(
                children: [
                  if (!showChatOnly)
                    SizedBox(
                      width: compact ? width - (outerPadding * 2) : 340,
                      child: _Sidebar(
                        controller: controller,
                        onOpenDirectChat: _openDirectChatDialog,
                        onOpenGroupChat: _openGroupChatDialog,
                        onOpenUsers: _openUsersDialog,
                        onOpenCurrentUserProfile: () async {
                          final user = controller.currentUser;
                          if (user != null) {
                            await _openUserProfile(user, allowStartChat: false);
                          }
                        },
                        onUploadAvatar: _pickAndUploadAvatar,
                        onOpenAdminPanel: _openAdminPanel,
                        onRefreshChats: controller.refreshChats,
                        onCheckServer: _showServerCheck,
                      ),
                    ),
                  if (!showSidebarOnly) ...[
                    if (!compact) const SizedBox(width: 12),
                    Expanded(
                      child: _ConversationPane(
                        controller: controller,
                        messageController: messageController,
                        scrollController: scrollController,
                        messageFocusNode: messageFocusNode,
                        replyTarget: replyTarget,
                        showScrollToBottom: _showScrollToBottom,
                        onScrollToBottom: () => _scheduleScrollToBottom(force: true),
                        onSubmitMessage: _submitMessage,
                        onSendImage: _pickAndSendImage,
                        onSendTriangleVideo: _pickAndSendTriangleVideo,
                        onOpenImage: _openImagePreview,
                        onReplyToMessage: _setReplyTarget,
                        onClearReply: _clearReplyTarget,
                        onAddMember: _openAddMemberDialog,
                        onOpenMembers: _openMembersProfileDialog,
                        onUpdateGroupIcon: _pickAndUpdateGroupIcon,
                        onOpenVoiceRoom: _openVoiceRoomPanel,
                        onToggleNotifications: selectedChat == null
                            ? null
                            : () => controller.setChatNotificationsEnabled(
                                  selectedChat.id,
                                  !selectedChat.notificationsEnabled,
                                ),
                        onRenameGroup: _openRenameGroupDialog,
                        onLeaveGroup: _confirmLeaveGroup,
                        onDeleteGroup: _confirmDeleteGroup,
                        onCreateDirectChat: _openDirectChatDialog,
                        onCreateGroupChat: _openGroupChatDialog,
                        onRefreshChat: controller.refreshChats,
                        onMessageMediaLoaded: _handleMessageMediaLoaded,
                        onOpenUserProfile: _openUserProfile,
                        onOpenHeaderUserProfile: selectedChat?.type == 'direct' && controller.directCounterpart(selectedChat!) != null
                            ? () => _openUserProfile(controller.directCounterpart(selectedChat)!)
                            : null,
                        onBack: compact ? controller.clearSelectedChat : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openDirectChatDialog() async {
    final controller = widget.controller;
    final email = await showDialog<String>(
      context: context,
      builder: (context) => const _DirectChatDialog(),
    );
    if (!mounted || email == null || email.isEmpty) {
      return;
    }
    await controller.createDirectChat(email);
  }

  Future<void> _openAddMemberDialog() async {
    final controller = widget.controller;
    final email = await showDialog<String>(
      context: context,
      builder: (context) => const _AddMemberDialog(),
    );
    if (!mounted || email == null || email.isEmpty) {
      return;
    }
    await controller.addMemberToSelectedChat(email);
  }

  Future<void> _openGroupChatDialog() async {
    final controller = widget.controller;
    final payload = await showDialog<_CreateGroupDialogResult>(
      context: context,
      builder: (context) => const _CreateGroupDialog(),
    );
    if (!mounted || payload == null) {
      return;
    }
    await controller.createGroupChat(
      title: payload.title,
      memberEmails: payload.memberEmails,
    );
  }

  Future<void> _openRenameGroupDialog() async {
    final controller = widget.controller;
    final chat = controller.selectedChat;
    if (chat == null || chat.type != 'group') {
      return;
    }
    final title = await showDialog<String>(
      context: context,
      builder: (context) => _RenameGroupDialog(initialTitle: chat.title ?? ''),
    );
    if (!mounted || title == null || title.trim().isEmpty) {
      return;
    }
    await controller.renameSelectedGroup(title);
  }

  Future<void> _confirmLeaveGroup() async {
    final controller = widget.controller;
    final chat = controller.selectedChat;
    final isPrivileged = controller.currentUser?.isAdmin == true || chat?.createdById == controller.currentUser?.id;
    if (chat == null || chat.type != 'group' || isPrivileged) {
      return;
    }
    final confirmed = await _confirmGroupAction(
      title: 'Leave group',
      body: 'You will leave "${controller.chatTitle(chat)}". You can only return if someone adds you again.',
      confirmLabel: 'Leave',
      confirmColor: const Color(0xFFE39A57),
    );
    if (!mounted || !confirmed) {
      return;
    }
    _clearReplyTarget();
    await controller.leaveSelectedGroup();
  }

  Future<void> _confirmDeleteGroup() async {
    final controller = widget.controller;
    final chat = controller.selectedChat;
    final isPrivileged = controller.currentUser?.isAdmin == true || chat?.createdById == controller.currentUser?.id;
    if (chat == null || chat.type != 'group' || !isPrivileged) {
      return;
    }
    final confirmed = await _confirmGroupAction(
      title: 'Delete group',
      body: 'This will permanently delete "${controller.chatTitle(chat)}" for every member.',
      confirmLabel: 'Delete',
      confirmColor: const Color(0xFFE07171),
    );
    if (!mounted || !confirmed) {
      return;
    }
    _clearReplyTarget();
    await controller.deleteSelectedGroup();
  }

  Future<bool> _confirmGroupAction({
    required String title,
    required String body,
    required String confirmLabel,
    required Color confirmColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: confirmColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _confirmRemoveMember(ChatMemberModel member) async {
    final controller = widget.controller;
    final chat = controller.selectedChat;
    if (chat == null || chat.type != 'group') {
      return;
    }
    final confirmed = await _confirmGroupAction(
      title: 'Remove member',
      body: 'Remove ${member.user.displayName} from "${controller.chatTitle(chat)}"?',
      confirmLabel: 'Remove',
      confirmColor: const Color(0xFFE07171),
    );
    if (!mounted || !confirmed) {
      return;
    }
    await controller.removeMemberFromSelectedGroup(member.user.id, member.user.displayName);
  }

  Future<void> _openUsersDialog() async {
    final controller = widget.controller;
    final usersFuture = controller.listUsers();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Users'),
          content: SizedBox(
            width: 420,
            child: FutureBuilder(
              future: usersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Text('Failed to load users\n\n${snapshot.error}');
                }
                final users = snapshot.data!;
                if (users.isEmpty) {
                  return const Text('No other registered users');
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: users.length,
                  separatorBuilder: (_, _) => const Divider(height: 18),
                  itemBuilder: (context, index) {
                    final user = users[index];
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _openUserProfile(user),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            CachedAvatar(
                              radius: 18,
                              label: user.displayName,
                              imageUrl: user.avatarUrl,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    user.email,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF8F98A3),
                                        ),
                                  ),
                                  if ((user.bio ?? '').trim().isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      user.bio!.trim(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: const Color(0xFFB8C4D0),
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () async {
                                final navigator = Navigator.of(context);
                                await controller.createDirectChat(user.email);
                                if (mounted) {
                                  navigator.pop();
                                }
                              },
                              tooltip: 'Open chat',
                              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openAdminPanel() async {
    if (widget.controller.currentUser?.isAdmin != true) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _AdminPanelDialog(controller: widget.controller),
    );
  }

  // ignore: unused_element
  Future<void> _openMembersDialog() async {
    final chat = widget.controller.selectedChat;
    if (chat == null || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(widget.controller.chatTitle(chat)),
          content: SizedBox(
            width: 420,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: chat.members.length,
              separatorBuilder: (_, _) => const Divider(height: 18),
              itemBuilder: (context, index) {
                final member = chat.members[index];
                final status = member.user.isOnline
                    ? 'Online'
                    : member.user.lastSeenAt == null
                        ? 'Offline'
                        : 'Last seen ${widget.controller.formatLastSeen(member.user.lastSeenAt!)}';
                return Row(
                  children: [
                    CachedAvatar(
                      radius: 18,
                      label: member.user.displayName,
                      imageUrl: member.user.avatarUrl,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(member.user.displayName),
                          const SizedBox(height: 2),
                          Text(
                            '${member.role} • $status',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF8F98A3),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openMembersProfileDialog() async {
    final chat = widget.controller.selectedChat;
    if (chat == null || !mounted) {
      return;
    }
    final currentUserId = widget.controller.currentUser?.id;
    final isOwner = chat.createdById == currentUserId || widget.controller.currentUser?.isAdmin == true;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(widget.controller.chatTitle(chat)),
          content: SizedBox(
            width: 420,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: chat.members.length,
              separatorBuilder: (_, _) => const Divider(height: 18),
              itemBuilder: (context, index) {
                final member = chat.members[index];
                final canRemove =
                    isOwner && member.user.id != currentUserId && member.role != 'owner';
                final status = member.user.isOnline
                    ? 'Online'
                    : member.user.lastSeenAt == null
                        ? 'Offline'
                        : 'Last seen ${widget.controller.formatLastSeen(member.user.lastSeenAt!)}';
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openUserProfile(member.user),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        CachedAvatar(
                          radius: 18,
                          label: member.user.displayName,
                          imageUrl: member.user.avatarUrl,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(member.user.displayName),
                              const SizedBox(height: 2),
                              Text(
                                '${member.role} • $status',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF8F98A3),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (canRemove)
                          IconButton(
                            onPressed: () => _confirmRemoveMember(member),
                            tooltip: 'Remove from group',
                            icon: const Icon(
                              Icons.person_remove_alt_1_rounded,
                              color: Color(0xFFE07171),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  UserModel _resolveUserProfile(UserModel user) {
    return widget.controller.userById(user.id) ?? user;
  }

  String _userStatusLabel(UserModel user) {
    if (user.isOnline) {
      return 'Online';
    }
    if (user.lastSeenAt == null) {
      return 'Offline';
    }
    return 'Last seen ${widget.controller.formatLastSeen(user.lastSeenAt!)}';
  }

  Future<void> _openUserProfile(
    UserModel user, {
    bool allowStartChat = true,
  }) async {
    final resolvedUser = _resolveUserProfile(user);
    final isCurrentUser = widget.controller.currentUser?.id == resolvedUser.id;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _UserProfileDialog(
          controller: widget.controller,
          user: resolvedUser,
          statusLabel: _userStatusLabel(resolvedUser),
          isCurrentUser: isCurrentUser,
          allowStartChat: allowStartChat && !isCurrentUser,
          onOpenAvatar: resolvedUser.avatarUrl == null || resolvedUser.avatarUrl!.isEmpty
              ? null
              : () => _openImagePreview(resolvedUser.avatarUrl!),
          onUploadAvatar: isCurrentUser ? _pickAndUploadAvatar : null,
        );
      },
    );
  }

  Future<PlatformFile?> _pickImageFile(String title) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    final file = result.files.first;
    if (file.bytes == null || file.bytes!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to read the selected file')),
        );
      }
      return null;
    }
    return file;
  }

  Future<void> _pickAndUploadAvatar() async {
    final file = await _pickImageFile('Choose avatar');
    if (file == null) {
      return;
    }
    await widget.controller.uploadAvatar(
      bytes: file.bytes!,
      filename: file.name,
    );
  }

  Future<void> _pickAndUpdateGroupIcon() async {
    final file = await _pickImageFile('Choose group icon');
    if (file == null) {
      return;
    }
    await widget.controller.updateSelectedGroupIcon(
      bytes: file.bytes!,
      filename: file.name,
    );
  }

  Future<void> _pickAndSendImage() async {
    final file = await _pickImageFile('Choose image');
    if (file == null) {
      return;
    }
    final sent = await widget.controller.sendImageMessage(
      bytes: file.bytes!,
      filename: file.name,
      body: messageController.text,
      replyToMessageId: replyTarget?.id,
    );
    if (sent) {
      messageController.clear();
      _clearReplyTarget();
      _focusComposer();
    }
  }

  Future<void> _pickAndSendTriangleVideo() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.92,
          child: TriangleVideoRecorderSheet(
            onSubmit: (bytes, filename) async {
              final sent = await widget.controller.sendTriangleVideoMessage(
                bytes: bytes,
                filename: filename,
                body: messageController.text,
                replyToMessageId: replyTarget?.id,
              );
              if (sent) {
                messageController.clear();
                _clearReplyTarget();
                _focusComposer();
              }
              return sent;
            },
          ),
        );
      },
    );
  }

  void _setReplyTarget(MessageModel message) {
    setState(() {
      replyTarget = message;
    });
    _scheduleScrollToBottom(force: true);
    _focusComposer();
  }

  void _clearReplyTarget() {
    if (!mounted) {
      replyTarget = null;
      return;
    }
    setState(() {
      replyTarget = null;
    });
  }

  Future<void> _openImagePreview(String imageUrl) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: const Color(0xFF0B0D10),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Center(
                    child: CachedImageView(
                      url: imageUrl,
                      fit: BoxFit.contain,
                      errorText: 'Image unavailable',
                      backgroundColor: const Color(0xFF0B0D10),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showServerCheck() async {
    final controller = widget.controller;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Server check'),
          content: FutureBuilder(
            future: controller.checkServerHealth(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  width: 260,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                );
              }
              if (snapshot.hasError) {
                return SizedBox(
                  width: 320,
                  child: Text('Request failed\n\n${snapshot.error}'),
                );
              }
              final result = snapshot.data!;
              return SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('URL: ${controller.config.apiBaseUrl}'),
                    const SizedBox(height: 8),
                    Text('Status: ${result.status}'),
                    const SizedBox(height: 8),
                    Text('Environment: ${result.environment}'),
                    const SizedBox(height: 8),
                    Text('Latency: ${result.latencyMs} ms'),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _handleScrollChanged() {
    _stickToBottom = _isNearBottom();
    final shouldShow = !_stickToBottom;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
    _checkLoadOlderMessages();
  }

  void _checkLoadOlderMessages() {
    if (!scrollController.hasClients) {
      return;
    }
    final position = scrollController.position;
    if (position.pixels <= 80) {
      final chat = widget.controller.selectedChat;
      if (chat != null &&
          widget.controller.hasMoreMessages(chat.id) &&
          !widget.controller.isLoadingMessages(chat.id)) {
        widget.controller.loadMessages(chat.id, loadMore: true);
      }
    }
  }

  bool _isNearBottom() {
    if (!scrollController.hasClients) {
      return true;
    }
    final position = scrollController.position;
    return (position.maxScrollExtent - position.pixels) <= 96;
  }

  void _scheduleScrollToBottom({bool force = false}) {
    if (!mounted) {
      return;
    }
    if (!force && !_stickToBottom) {
      return;
    }
    _bottomSettleTimer?.cancel();
    _bottomSettleTimer = null;
    _scrollToBottom(animated: false);
    if (force) {
      _bottomSettleTimer = Timer(const Duration(milliseconds: 50), () {
        _bottomSettleTimer = null;
        _scrollToBottom(animated: false);
      });
      return;
    }
    var attemptsLeft = 3;
    _bottomSettleTimer = Timer.periodic(const Duration(milliseconds: 140), (timer) {
      if (!mounted || !scrollController.hasClients || !_stickToBottom) {
        timer.cancel();
        if (identical(_bottomSettleTimer, timer)) {
          _bottomSettleTimer = null;
        }
        return;
      }
      _scrollToBottom(animated: true);
      attemptsLeft -= 1;
      if (attemptsLeft <= 0) {
        timer.cancel();
        if (identical(_bottomSettleTimer, timer)) {
          _bottomSettleTimer = null;
        }
      }
    });
  }

  void _scrollToBottom({bool animated = true}) {
    if (!mounted) {
      return;
    }
    if (!scrollController.hasClients) {
      return;
    }
    final target = scrollController.position.maxScrollExtent;
    try {
      if (animated) {
        scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
        return;
      }
      scrollController.jumpTo(target);
    } catch (_) {
      return;
    }
  }

  void _handleMessageMediaLoaded() {
    _scheduleScrollToBottom();
  }

  void _focusComposer() {
    if (!mounted) {
      return;
    }
    messageFocusNode.requestFocus();
  }

  Future<void> _submitMessage() async {
    final text = messageController.text;
    if (text.trim().isEmpty) {
      _focusComposer();
      return;
    }
    final sent = await widget.controller.sendMessage(
      text,
      replyToMessageId: replyTarget?.id,
    );
    if (sent) {
      messageController.clear();
      _clearReplyTarget();
      _focusComposer();
    }
  }

  Future<void> _openVoiceRoomPanel() async {
    final controller = widget.controller;
    final chat = controller.selectedChat;
    if (chat == null) {
      return;
    }
    await controller.loadVoiceState(chat.id);
    if (!mounted) {
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final content = AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final activeChat = controller.selectedChat;
        final targetChat = activeChat?.id == chat.id ? activeChat! : chat;
        return _VoiceRoomPanel(
          controller: controller,
          chatTitle: controller.chatTitle(targetChat),
          isGroupChat: targetChat.type == 'group',
          currentUserId: controller.currentUser?.id,
          canModerateParticipants: targetChat.type == 'group' &&
              (controller.currentUser?.isAdmin == true ||
                  targetChat.members.any(
                    (member) => member.user.id == controller.currentUser?.id && member.role == 'owner',
                  )),
          state: controller.voiceStateForChat(chat.id),
          speakingUserIds: controller.speakingVoiceUserIds,
          onJoin: controller.joinSelectedVoiceRoom,
          onLeave: controller.leaveVoiceRoom,
          onToggleMute: controller.toggleVoiceMute,
          onRefresh: () => controller.loadVoiceState(chat.id),
          onSetMasterVolume: controller.setVoiceMasterVolume,
          onSetParticipantVolume: controller.setVoiceParticipantVolume,
          onMuteParticipant: _muteVoiceParticipant,
          onKickParticipant: _kickVoiceParticipant,
          onToggleCamera: _toggleVoiceCamera,
          onToggleScreenShare: _toggleVoiceScreenShare,
          onOpenUserProfile: _openUserProfile,
        );
      },
    );
    if (width < 760) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF0B0D10),
        builder: (context) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.86,
                child: content,
              ),
            ),
          );
        },
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF0B0D10),
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 860,
            height: 760,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: content,
            ),
          ),
        );
      },
    );
  }

  Future<void> _muteVoiceParticipant(UserModel user) async {
    await widget.controller.muteVoiceParticipant(user.id, user.displayName);
  }

  Future<void> _kickVoiceParticipant(UserModel user) async {
    final chat = widget.controller.selectedChat;
    if (chat == null) {
      return;
    }
    final confirmed = await _confirmGroupAction(
      title: 'Remove from voice',
      body: 'Remove ${user.displayName} from the voice room in "${widget.controller.chatTitle(chat)}"?',
      confirmLabel: 'Remove',
      confirmColor: const Color(0xFFE07171),
    );
    if (!mounted || !confirmed) {
      return;
    }
    await widget.controller.kickVoiceParticipant(user.id, user.displayName);
  }

  Future<void> _toggleVoiceCamera() async {
    await widget.controller.toggleVoiceCamera();
  }

  Future<void> _toggleVoiceScreenShare() async {
    final controller = widget.controller;
    if (controller.voiceScreenShareEnabled) {
      await controller.setVoiceScreenShareEnabled(false);
      return;
    }
    String? desktopSourceId;
    if (lk.lkPlatformIsDesktop()) {
      final source = await _pickDesktopScreenShareSource();
      if (!mounted || source == null) {
        return;
      }
      desktopSourceId = source.id;
    }
    await controller.setVoiceScreenShareEnabled(true, desktopSourceId: desktopSourceId);
  }

  Future<rtc.DesktopCapturerSource?> _pickDesktopScreenShareSource() async {
    final sources = await rtc.desktopCapturer.getSources(
      types: const [rtc.SourceType.Screen, rtc.SourceType.Window],
      thumbnailSize: rtc.ThumbnailSize(320, 180),
    );
    if (!mounted || sources.isEmpty) {
      return null;
    }
    final orderedSources = [...sources]..sort((left, right) {
      if (left.type != right.type) {
        return left.type == rtc.SourceType.Screen ? -1 : 1;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    rtc.DesktopCapturerSource? selectedSource = orderedSources.first;
    return showDialog<rtc.DesktopCapturerSource>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              backgroundColor: const Color(0xFF0B0D10),
              insetPadding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 720,
                height: 560,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose What To Share',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Pick a screen or window for screen sharing.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF8F98A3),
                            ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: GridView.builder(
                          itemCount: orderedSources.length,
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.45,
                          ),
                          itemBuilder: (context, index) {
                            final source = orderedSources[index];
                            final selected = selectedSource?.id == source.id;
                            return InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => setState(() => selectedSource = source),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF121821),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: selected ? const Color(0xFF67D1A9) : const Color(0xFF1D2631),
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                                        child: source.thumbnail != null
                                            ? Image.memory(
                                                source.thumbnail!,
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                                gaplessPlayback: true,
                                              )
                                            : Container(
                                                width: double.infinity,
                                                color: const Color(0xFF0F141B),
                                                alignment: Alignment.center,
                                                child: Icon(
                                                  source.type == rtc.SourceType.Screen
                                                      ? Icons.desktop_windows_rounded
                                                      : Icons.crop_square_rounded,
                                                  color: const Color(0xFF8F98A3),
                                                  size: 30,
                                                ),
                                              ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            source.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            source.type == rtc.SourceType.Screen ? 'Screen' : 'Window',
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                  color: const Color(0xFF8F98A3),
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: selectedSource == null
                                ? null
                                : () => Navigator.of(context).pop(selectedSource),
                            icon: const Icon(Icons.screen_share_rounded),
                            label: const Text('Share'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.controller,
    required this.onOpenDirectChat,
    required this.onOpenGroupChat,
    required this.onOpenUsers,
    required this.onOpenCurrentUserProfile,
    required this.onUploadAvatar,
    required this.onOpenAdminPanel,
    required this.onRefreshChats,
    required this.onCheckServer,
  });

  final AppController controller;
  final Future<void> Function() onOpenDirectChat;
  final Future<void> Function() onOpenGroupChat;
  final Future<void> Function() onOpenUsers;
  final Future<void> Function() onOpenCurrentUserProfile;
  final Future<void> Function() onUploadAvatar;
  final Future<void> Function() onOpenAdminPanel;
  final Future<void> Function() onRefreshChats;
  final Future<void> Function() onCheckServer;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  Future<void> _confirmLogout(BuildContext context, AppController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sign out'),
          content: const Text('Are you sure you want to sign out?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE07171),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await controller.logout();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final currentUser = controller.currentUser;
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 14),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.all(compact ? 10 : 14),
              decoration: BoxDecoration(
                color: const Color(0xFF121821),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1D2631)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: widget.onOpenCurrentUserProfile,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            CachedAvatar(
                              radius: 22,
                              label: currentUser?.displayName ?? 'K',
                              imageUrl: currentUser?.avatarUrl,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    currentUser?.displayName ?? 'Unknown user',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    currentUser?.email ?? '',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF8F98A3),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onUploadAvatar,
                    tooltip: 'Change avatar',
                    icon: const Icon(Icons.add_a_photo_outlined),
                  ),
                  IconButton(
                    onPressed: widget.onRefreshChats,
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    onPressed: () => _confirmLogout(context, controller),
                    tooltip: 'Logout',
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(compact ? 10 : 12),
              decoration: BoxDecoration(
                color: const Color(0xFF10161E),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF1D2631)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF121821),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF233041)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: switch (controller.connectionStatus) {
                                    'connected' => const Color(0xFF57D18C),
                                    'connecting' => const Color(0xFFE0B45B),
                                    'error' => const Color(0xFFE07171),
                                    _ => const Color(0xFFE07171),
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  controller.connectionLabel(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: widget.onCheckServer,
                        icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
                        label: const Text('Check'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: widget.onOpenDirectChat,
                          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                          label: const Text('New direct'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: widget.onOpenGroupChat,
                          icon: const Icon(Icons.groups_rounded, size: 18),
                          label: const Text('New group'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onOpenUsers,
                          icon: const Icon(Icons.people_alt_outlined, size: 16),
                          label: const Text('All users'),
                        ),
                      ),
                      if (currentUser?.isAdmin == true) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: widget.onOpenAdminPanel,
                            icon: const Icon(Icons.admin_panel_settings_outlined, size: 16),
                            label: const Text('Admin'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  controller.errorMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFF7B7B),
                      ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF121821),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF1D2631)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded, size: 18, color: Color(0xFF8F98A3)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
                      style: const TextStyle(fontSize: 13.5),
                      decoration: const InputDecoration(
                        hintText: 'Search chats...',
                        hintStyle: TextStyle(color: Color(0xFF8F98A3)),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                      child: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF8F98A3)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: controller.chatsLoading && controller.chats.isEmpty
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
                  : controller.chats.isEmpty
                      ? Center(
                          child: Text(
                            'No conversations yet',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: const Color(0xFF8F98A3),
                                ),
                          ),
                        )
                      : Builder(
                          builder: (context) {
                            final filteredChats = _searchQuery.isEmpty
                                ? controller.chats
                                : controller.chats.where((chat) {
                                    return controller.chatTitle(chat).toLowerCase().contains(_searchQuery);
                                  }).toList();
                            if (filteredChats.isEmpty) {
                              return Center(
                                child: Text(
                                  'No chats found',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: const Color(0xFF8F98A3),
                                      ),
                                ),
                              );
                            }
                            return ListView.separated(
                              itemCount: filteredChats.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final chat = filteredChats[index];
                                final counterpart = controller.directCounterpart(chat);
                                final isOnline = chat.type == 'direct'
                                    ? (counterpart?.isOnline ?? false)
                                    : chat.members.any((m) => m.user.isOnline && m.user.id != currentUser?.id);
                                return ChatListTile(
                                  title: controller.chatTitle(chat),
                                  preview: controller.chatPreview(chat),
                                  meta: controller.formatChatListTime(chat.lastMessage?.createdAt ?? chat.updatedAt),
                                  avatarLabel: controller.chatTitle(chat),
                                  avatarUrl: chat.type == 'group'
                                      ? chat.iconUrl
                                      : counterpart?.avatarUrl,
                                  unreadCount: chat.unreadCount,
                                  notificationsEnabled: chat.notificationsEnabled,
                                  selected: chat.id == controller.selectedChatId,
                                  onTap: () => controller.selectChat(chat.id),
                                  isOnline: isOnline,
                                  typingText: controller.typingTextForChat(chat),
                                );
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.controller,
    required this.messageController,
    required this.scrollController,
    required this.messageFocusNode,
    required this.replyTarget,
    required this.showScrollToBottom,
    required this.onScrollToBottom,
    required this.onSubmitMessage,
    required this.onSendImage,
    required this.onSendTriangleVideo,
    required this.onOpenImage,
    required this.onReplyToMessage,
    required this.onClearReply,
    required this.onAddMember,
    required this.onOpenMembers,
    required this.onUpdateGroupIcon,
    required this.onOpenVoiceRoom,
    required this.onToggleNotifications,
    required this.onRenameGroup,
    required this.onLeaveGroup,
    required this.onDeleteGroup,
    required this.onCreateDirectChat,
    required this.onCreateGroupChat,
    required this.onRefreshChat,
    required this.onMessageMediaLoaded,
    required this.onOpenUserProfile,
    this.onOpenHeaderUserProfile,
    this.onBack,
  });

  final AppController controller;
  final TextEditingController messageController;
  final ScrollController scrollController;
  final FocusNode messageFocusNode;
  final MessageModel? replyTarget;
  final bool showScrollToBottom;
  final VoidCallback onScrollToBottom;
  final Future<void> Function() onSubmitMessage;
  final Future<void> Function() onSendImage;
  final Future<void> Function() onSendTriangleVideo;
  final void Function(String imageUrl) onOpenImage;
  final void Function(MessageModel message) onReplyToMessage;
  final VoidCallback onClearReply;
  final Future<void> Function() onAddMember;
  static Widget _buildDateSeparator(BuildContext context, DateTime dateTime) {
    final local = dateTime.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(local.year, local.month, local.day);
    final difference = today.difference(messageDate);

    String label;
    if (difference.inDays == 0) {
      label = 'Today';
    } else if (difference.inDays == 1) {
      label = 'Yesterday';
    } else if (difference.inDays < 7) {
      const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      label = weekdays[local.weekday - 1];
    } else {
      label = '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF121821),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF1D2631)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8F98A3),
            ),
          ),
        ),
      ),
    );
  }

  final Future<void> Function() onOpenMembers;
  final Future<void> Function() onUpdateGroupIcon;
  final Future<void> Function() onOpenVoiceRoom;
  final Future<bool> Function()? onToggleNotifications;
  final Future<void> Function() onRenameGroup;
  final Future<void> Function() onLeaveGroup;
  final Future<void> Function() onDeleteGroup;
  final Future<void> Function() onCreateDirectChat;
  final Future<void> Function() onCreateGroupChat;
  final Future<void> Function() onRefreshChat;
  final VoidCallback onMessageMediaLoaded;
  final Future<void> Function(UserModel user) onOpenUserProfile;
  final Future<void> Function()? onOpenHeaderUserProfile;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final selectedChat = controller.selectedChat;
    if (selectedChat == null) {
      return Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF151B23),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF202734)),
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 32,
                    color: Color(0xFF4A5563),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Select a chat',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  'Start a direct conversation or create a group.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF8F98A3),
                      ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onCreateDirectChat,
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('New direct'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onCreateGroupChat,
                      icon: const Icon(Icons.group_add_rounded),
                      label: const Text('New group'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    final messages = controller.selectedMessages;
    final isLoading = controller.isLoadingMessages(selectedChat.id);
    final counterpart = controller.directCounterpart(selectedChat);
    final headerImage = selectedChat.type == 'group' ? selectedChat.iconUrl : counterpart?.avatarUrl;
    final isReadOnlySystemChat = selectedChat.type == 'direct' && (counterpart?.isSystem ?? false);
    final isGroupOwner =
        selectedChat.type == 'group' &&
        (selectedChat.createdById == controller.currentUser?.id || controller.currentUser?.isAdmin == true);
    final compactLayout = MediaQuery.sizeOf(context).width < 760;
    return Card(
      child: Padding(
        padding: compactLayout
            ? const EdgeInsets.fromLTRB(8, 8, 8, 6)
            : const EdgeInsets.fromLTRB(14, 14, 12, 8),
        child: Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final compactHeader = constraints.maxWidth < 760;
                final canManageGroup = selectedChat.type == 'group';
                final actions = <Widget>[
                  IconButton(
                    onPressed: onRefreshChat,
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    onPressed: onOpenVoiceRoom,
                    tooltip: selectedChat.type == 'group' ? 'Voice room' : 'Voice call',
                    icon: Badge(
                      isLabelVisible: (controller.voiceStateForChat(selectedChat.id)?.participants.length ?? 0) > 0,
                      label: Text('${controller.voiceStateForChat(selectedChat.id)?.participants.length ?? 0}'),
                      child: const Icon(Icons.graphic_eq_rounded),
                    ),
                  ),
                  IconButton(
                    onPressed: onToggleNotifications == null ? null : () => onToggleNotifications!(),
                    tooltip: selectedChat.notificationsEnabled
                        ? 'Disable notifications'
                        : 'Enable notifications',
                    icon: Icon(
                      selectedChat.notificationsEnabled
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_off_rounded,
                    ),
                  ),
                  if (selectedChat.type == 'group')
                    IconButton(
                      onPressed: onOpenMembers,
                      tooltip: 'Members',
                      icon: const Icon(Icons.groups_rounded),
                    ),
                  if (canManageGroup)
                    PopupMenuButton<String>(
                      tooltip: 'Group actions',
                      onSelected: (value) {
                        if (value == 'add_member') {
                          unawaited(onAddMember());
                        } else if (value == 'change_icon') {
                          unawaited(onUpdateGroupIcon());
                        } else if (value == 'rename') {
                          unawaited(onRenameGroup());
                        } else if (value == 'leave') {
                          unawaited(onLeaveGroup());
                        } else if (value == 'delete') {
                          unawaited(onDeleteGroup());
                        }
                      },
                      itemBuilder: (context) => [
                        if (isGroupOwner)
                          const PopupMenuItem<String>(
                            value: 'add_member',
                            child: Text('Add member'),
                          ),
                        if (isGroupOwner)
                          const PopupMenuItem<String>(
                            value: 'change_icon',
                            child: Text('Change group icon'),
                          ),
                        if (isGroupOwner)
                          const PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('Rename group'),
                          ),
                        if (!isGroupOwner)
                          const PopupMenuItem<String>(
                            value: 'leave',
                            child: Text('Leave group'),
                          ),
                        if (isGroupOwner)
                          const PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('Delete group'),
                          ),
                      ],
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
                ];
                final headerInfo = InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: onOpenHeaderUserProfile,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        CachedAvatar(
                          radius: 22,
                          label: controller.chatTitle(selectedChat),
                          imageUrl: headerImage,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                controller.chatTitle(selectedChat),
                                style: Theme.of(context).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                controller.chatSubtitle(selectedChat),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF8F98A3),
                                    ),
                              ),
                              if (controller.voiceStateForChat(selectedChat.id)?.participants.isNotEmpty ?? false)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    controller.voiceSummaryForChat(selectedChat),
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF67D1A9),
                                        ),
                                  ),
                                ),
                              if (controller.activeVoiceChatId == selectedChat.id)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Voice ${controller.voiceConnectionLabel()}',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: controller.voiceConnectionStatus == 'reconnecting'
                                              ? const Color(0xFFFFC857)
                                              : const Color(0xFF67D1A9),
                                        ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                if (compactHeader) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (onBack != null)
                            IconButton(
                              onPressed: onBack,
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                          Expanded(child: headerInfo),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: actions,
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    if (onBack != null)
                      IconButton(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    Expanded(child: headerInfo),
                    ...actions,
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: isLoading && messages.isEmpty
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
                  : messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.forum_outlined,
                                size: 40,
                                color: const Color(0xFF2A3441),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No messages yet',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF8F98A3),
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Send the first message to start a conversation',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF4A5563),
                                    ),
                              ),
                            ],
                          ),
                        )
                      : Stack(
                          children: [
                            ListView.builder(
                          controller: scrollController,
                          padding: EdgeInsets.only(right: compactLayout ? 0 : 2),
                          itemCount: messages.length + (controller.hasMoreMessages(selectedChat.id) ? 1 : 0),
                          itemBuilder: (context, index) {
                            final hasMoreOffset = controller.hasMoreMessages(selectedChat.id) ? 1 : 0;
                            if (hasMoreOffset == 1 && index == 0) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: isLoading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : TextButton(
                                          onPressed: () => controller.loadMessages(selectedChat.id, loadMore: true),
                                          child: const Text('Load older messages'),
                                        ),
                                ),
                              );
                            }
                            final msgIndex = index - hasMoreOffset;
                            final message = messages[msgIndex];
                            final isOwn = message.sender.id == controller.currentUser?.id;

                            Widget? dateSeparator;
                            if (msgIndex == 0) {
                              dateSeparator = _buildDateSeparator(context, message.createdAt);
                            } else {
                              final prevMessage = messages[msgIndex - 1];
                              final prevDate = prevMessage.createdAt.toLocal();
                              final currDate = message.createdAt.toLocal();
                              if (prevDate.year != currDate.year ||
                                  prevDate.month != currDate.month ||
                                  prevDate.day != currDate.day) {
                                dateSeparator = _buildDateSeparator(context, message.createdAt);
                              }
                            }

                            final isFirstInGroup = msgIndex == 0 ||
                                messages[msgIndex - 1].sender.id != message.sender.id ||
                                messages[msgIndex - 1].isSystem ||
                                message.isSystem ||
                                dateSeparator != null;
                            final isLastInGroup = msgIndex == messages.length - 1 ||
                                messages[msgIndex + 1].sender.id != message.sender.id ||
                                messages[msgIndex + 1].isSystem ||
                                message.isSystem;

                            final showSender = selectedChat.type == 'group' && !isOwn && isFirstInGroup;
                            final showAvatar = !isOwn && isLastInGroup;

                            return Column(
                              children: [
                                ?dateSeparator,
                                MessageBubble(
                                  message: message,
                                  isOwn: isOwn,
                                  timeLabel: controller.formatClock(message.createdAt),
                                  deliveryStatus: controller.deliveryStatus(message),
                                  avatarLabel: message.sender.displayName,
                                  avatarUrl: message.sender.avatarUrl,
                                  showSender: showSender,
                                  showAvatar: showAvatar,
                                  onOpenSenderProfile: selectedChat.type == 'group' && !isOwn
                                      ? () => onOpenUserProfile(message.sender)
                                      : null,
                                  onReply: message.isSystem ? null : () => onReplyToMessage(message),
                                  onOpenImage: (message.imageUrl ?? '').isNotEmpty
                                      ? () => onOpenImage(message.imageUrl!)
                                      : null,
                                  onMediaLoaded: (message.imageUrl ?? '').isNotEmpty ? onMessageMediaLoaded : null,
                                  onRetry: message.localState == MessageLocalState.failed && controller.canRetryMessage(message)
                                      ? () => controller.retryFailedMessage(message.id)
                                      : null,
                                  onShowReadReceipts: isOwn && selectedChat.type == 'group' && message.localState == MessageLocalState.none
                                      ? () => _showMessageInsightsDialog(context, controller, selectedChat, message)
                                      : null,
                                  onShowMessageInsights: selectedChat.type == 'group' && !message.isSystem && message.localState == MessageLocalState.none
                                      ? () => _showMessageInsightsDialog(context, controller, selectedChat, message)
                                      : null,
                                  apiClient: controller.api,
                                  onReact: message.isSystem || message.localState != MessageLocalState.none
                                      ? null
                                      : (emoji) {
                                          final keepPinnedToBottom = !scrollController.hasClients ||
                                              (scrollController.position.maxScrollExtent - scrollController.position.pixels) <= 96;
                                          controller.toggleReaction(selectedChat.id, message.id, emoji);
                                          if (keepPinnedToBottom) {
                                            onScrollToBottom();
                                          }
                                        },
                                ),
                              ],
                            );
                          },
                        ),
                            if (showScrollToBottom)
                              Positioned(
                                right: 12,
                                bottom: 12,
                                child: Material(
                                  color: const Color(0xFF1B232D),
                                  shape: const CircleBorder(
                                    side: BorderSide(color: Color(0xFF2A3441)),
                                  ),
                                  elevation: 4,
                                  shadowColor: Colors.black54,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(999),
                                    onTap: onScrollToBottom,
                                    child: const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 22,
                                        color: Color(0xFFCFD6DE),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(compactLayout ? 4 : 6),
              decoration: BoxDecoration(
                color: const Color(0xFF121821),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF1D2631)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isReadOnlySystemChat)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: EdgeInsets.symmetric(
                        horizontal: compactLayout ? 10 : 12,
                        vertical: compactLayout ? 8 : 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F141B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF202734)),
                      ),
                      child: Text(
                        'Kaftar system account. You can receive updates here, but you cannot reply.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFB8C4D0),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  if (replyTarget != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: EdgeInsets.symmetric(
                        horizontal: compactLayout ? 10 : 12,
                        vertical: compactLayout ? 8 : 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F141B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF202734)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Replying to ${replyTarget!.sender.displayName}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFFCFD6DE),
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  replyTarget!.isTriangleVideo
                                      ? (replyTarget!.body.isNotEmpty && replyTarget!.body != 'Triangle video'
                                          ? 'Triangle video - ${replyTarget!.body}'
                                          : 'Triangle video')
                                      : (replyTarget!.imageUrl ?? '').isNotEmpty
                                          ? (replyTarget!.body.isNotEmpty ? 'Photo - ${replyTarget!.body}' : 'Photo')
                                          : replyTarget!.body,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF8F98A3),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: onClearReply,
                            tooltip: 'Cancel reply',
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: isReadOnlySystemChat ? null : onSendImage,
                        tooltip: 'Send image',
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                      ),
                      const SizedBox(width: 4),
                      _TriangleComposerButton(
                        enabled: !isReadOnlySystemChat,
                        onPressed: onSendTriangleVideo,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Focus(
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent) {
                              return KeyEventResult.ignored;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.enter &&
                                !HardwareKeyboard.instance.isShiftPressed) {
                              onSubmitMessage();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: TextField(
                            controller: messageController,
                            focusNode: messageFocusNode,
                            autofocus: true,
                            textCapitalization: TextCapitalization.sentences,
                            enabled: !isReadOnlySystemChat,
                            readOnly: isReadOnlySystemChat,
                            minLines: 1,
                            maxLines: 5,
                            onChanged: isReadOnlySystemChat ? null : controller.handleComposerChanged,
                            decoration: InputDecoration(
                              hintText: isReadOnlySystemChat
                                  ? 'Read-only system chat'
                                  : (replyTarget == null ? 'Write a message' : 'Write a reply'),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: controller.composerSending || isReadOnlySystemChat ? null : onSubmitMessage,
                        tooltip: 'Send',
                        icon: controller.composerSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void _showMessageInsightsDialog(
    BuildContext context,
    AppController controller,
    ChatModel chat,
    MessageModel message,
  ) {
    final otherMembers = chat.members.where((m) => m.user.id != message.sender.id).toList();
    final reactionsByUserId = {
      for (final reaction in message.reactions) reaction.user.id: reaction,
    };
    final viewedMembers = <_MessageInsightEntry>[];
    final pendingMembers = <_MessageInsightEntry>[];
    for (final member in otherMembers) {
      final reaction = reactionsByUserId[member.user.id];
      final readAt = member.lastReadAt;
      final hasReadReceipt = readAt != null && !readAt.isBefore(message.createdAt);
      final viewedAt = hasReadReceipt ? readAt : reaction?.createdAt;
      final entry = _MessageInsightEntry(
        member: member,
        reaction: reaction,
        viewedAt: viewedAt,
      );
      if (viewedAt != null) {
        viewedMembers.add(entry);
      } else {
        pendingMembers.add(entry);
      }
    }
    viewedMembers.sort((left, right) => right.viewedAt!.compareTo(left.viewedAt!));
    pendingMembers.sort((left, right) => left.member.user.displayName.toLowerCase().compareTo(right.member.user.displayName.toLowerCase()));

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Message info'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sent ${controller.formatDetailedDateTime(message.createdAt)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8F98A3),
                    ),
                  ),
                  if (viewedMembers.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Viewed \u2022 ${viewedMembers.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8F98A3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...viewedMembers.map(
                      (entry) => _MessageInsightRow(
                        controller: controller,
                        entry: entry,
                        viewed: true,
                      ),
                    ),
                  ],
                  if (pendingMembers.isNotEmpty) ...[
                    if (viewedMembers.isNotEmpty) const SizedBox(height: 14),
                    Text(
                      'Not viewed \u2022 ${pendingMembers.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8F98A3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...pendingMembers.map(
                      (entry) => _MessageInsightRow(
                        controller: controller,
                        entry: entry,
                        viewed: false,
                      ),
                    ),
                  ],
                  if (otherMembers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'No other members',
                        style: TextStyle(color: Color(0xFF8F98A3)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _TriangleComposerButton extends StatelessWidget {
  const _TriangleComposerButton({
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? const Color(0xFFE6EDF5) : const Color(0xFF66707A);
    return IconButton(
      onPressed: enabled ? () => unawaited(onPressed()) : null,
      tooltip: 'Record triangle video',
      icon: CustomPaint(
        size: const Size(18, 18),
        painter: _TriangleComposerGlyphPainter(
          color: iconColor,
        ),
      ),
    );
  }
}

class _TriangleComposerGlyphPainter extends CustomPainter {
  const _TriangleComposerGlyphPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, size.height * 0.14)
      ..lineTo(size.width * 0.84, size.height * 0.82)
      ..lineTo(size.width * 0.16, size.height * 0.82)
      ..close();

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeJoin = StrokeJoin.round;
    final accent = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, stroke);
    canvas.drawCircle(
      Offset(size.width / 2, size.height * 0.42),
      1.45,
      accent,
    );
  }

  @override
  bool shouldRepaint(covariant _TriangleComposerGlyphPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _MessageInsightEntry {
  const _MessageInsightEntry({
    required this.member,
    required this.reaction,
    required this.viewedAt,
  });

  final ChatMemberModel member;
  final MessageReactionModel? reaction;
  final DateTime? viewedAt;
}

class _MessageInsightRow extends StatelessWidget {
  const _MessageInsightRow({
    required this.controller,
    required this.entry,
    required this.viewed,
  });

  final AppController controller;
  final _MessageInsightEntry entry;
  final bool viewed;

  @override
  Widget build(BuildContext context) {
    final reaction = entry.reaction;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            viewed ? Icons.done_all_rounded : Icons.done_rounded,
            size: 16,
            color: viewed ? const Color(0xFF67D1A9) : const Color(0xFF8F98A3),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.member.user.displayName,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  viewed && entry.viewedAt != null
                      ? 'Viewed ${controller.formatDetailedDateTime(entry.viewedAt!)}'
                      : 'No view yet',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8F98A3),
                  ),
                ),
              ],
            ),
          ),
          if (reaction != null)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF121821),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2A3441)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    reaction.emoji,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    controller.formatDetailedDateTime(reaction.createdAt),
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8F98A3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _UserProfileDialog extends StatefulWidget {
  const _UserProfileDialog({
    required this.controller,
    required this.user,
    required this.statusLabel,
    required this.isCurrentUser,
    required this.allowStartChat,
    this.onOpenAvatar,
    this.onUploadAvatar,
  });

  final AppController controller;
  final UserModel user;
  final String statusLabel;
  final bool isCurrentUser;
  final bool allowStartChat;
  final VoidCallback? onOpenAvatar;
  final Future<void> Function()? onUploadAvatar;

  @override
  State<_UserProfileDialog> createState() => _UserProfileDialogState();
}

class _DirectChatDialog extends StatefulWidget {
  const _DirectChatDialog();

  @override
  State<_DirectChatDialog> createState() => _DirectChatDialogState();
}

class _DirectChatDialogState extends State<_DirectChatDialog> {
  late final TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New direct chat'),
      content: TextField(
        controller: _emailController,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Email'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _submit() {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      return;
    }
    Navigator.of(context).pop(email);
  }
}

class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  late final TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add member'),
      content: TextField(
        controller: _emailController,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Email'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }

  void _submit() {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      return;
    }
    Navigator.of(context).pop(email);
  }
}

class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final TextEditingController _titleController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename group'),
      content: TextField(
        controller: _titleController,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Title'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      return;
    }
    Navigator.of(context).pop(title);
  }
}

class _CreateGroupDialogResult {
  const _CreateGroupDialogResult({
    required this.title,
    required this.memberEmails,
  });

  final String title;
  final List<String> memberEmails;
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _emailsController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _emailsController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _emailsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New group'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailsController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Member emails',
                hintText: 'one@example.com, two@example.com',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _submit() {
    final title = _titleController.text.trim();
    final emails = _emailsController.text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (title.isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      _CreateGroupDialogResult(
        title: title,
        memberEmails: emails,
      ),
    );
  }
}

class _AdminPanelDialog extends StatefulWidget {
  const _AdminPanelDialog({required this.controller});

  final AppController controller;

  @override
  State<_AdminPanelDialog> createState() => _AdminPanelDialogState();
}

class _AdminPanelDialogState extends State<_AdminPanelDialog> {
  late Future<List<UserModel>> _usersFuture;
  final Set<String> _processingUserIds = <String>{};

  @override
  void initState() {
    super.initState();
    _usersFuture = widget.controller.listUsers();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Admin panel'),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<UserModel>>(
          future: _usersFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              );
            }
            if (snapshot.hasError) {
              return Text('Failed to load users\n\n${snapshot.error}');
            }
            final users = snapshot.data ?? const <UserModel>[];
            if (users.isEmpty) {
              return const Text('No users available for admin actions');
            }
            return ListView.separated(
              shrinkWrap: true,
              itemCount: users.length,
              separatorBuilder: (_, _) => const Divider(height: 18),
              itemBuilder: (context, index) {
                final user = users[index];
                final isBusy = _processingUserIds.contains(user.id);
                final status = user.isOnline
                    ? 'Online'
                    : user.lastSeenAt == null
                        ? 'Offline'
                        : 'Last seen ${widget.controller.formatLastSeen(user.lastSeenAt!)}';
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CachedAvatar(
                      radius: 18,
                      label: user.displayName,
                      imageUrl: user.avatarUrl,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            user.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF8F98A3),
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            status,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF8F98A3),
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: isBusy
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Revoke all sessions'),
                                  content: Text(
                                    'Force ${user.displayName} to sign in again on all devices?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.of(context).pop(true),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: const Color(0xFFE07171),
                                      ),
                                      child: const Text('Revoke'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true || !mounted) {
                                return;
                              }
                              setState(() => _processingUserIds.add(user.id));
                              await widget.controller.revokeAllSessionsForUser(user);
                              if (mounted) {
                                setState(() => _processingUserIds.remove(user.id));
                              }
                            },
                      icon: isBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.block_rounded, size: 16),
                      label: const Text('Revoke sessions'),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _UserProfileDialogState extends State<_UserProfileDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _bioController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(text: widget.user.displayName);
    _bioController = TextEditingController(text: widget.user.bio ?? '');
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = widget.user;
    return AlertDialog(
      title: Text(widget.isCurrentUser ? 'My profile' : 'User profile'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(56),
                      onTap: widget.onOpenAvatar,
                      child: CachedAvatar(
                        radius: 52,
                        label: user.displayName,
                        imageUrl: user.avatarUrl,
                      ),
                    ),
                    if (widget.onOpenAvatar != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Tap avatar to view',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF8F98A3),
                          ),
                        ),
                      ),
                    if (widget.isCurrentUser && widget.onUploadAvatar != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextButton.icon(
                          onPressed: widget.onUploadAvatar,
                          icon: const Icon(Icons.add_a_photo_outlined),
                          label: const Text('Change avatar'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (widget.isCurrentUser)
                TextField(
                  controller: _displayNameController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 255,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                _ProfileField(
                  label: 'Name',
                  value: user.displayName,
                ),
              const SizedBox(height: 10),
              _ProfileField(
                label: 'Email',
                value: user.email,
              ),
              const SizedBox(height: 10),
              _ProfileField(
                label: 'Status',
                value: widget.statusLabel,
              ),
              const SizedBox(height: 14),
              Text(
                'Bio',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFFCFD6DE),
                ),
              ),
              const SizedBox(height: 8),
              if (widget.isCurrentUser)
                TextField(
                  controller: _bioController,
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    hintText: 'Tell something about yourself',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121821),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF1D2631)),
                  ),
                  child: Text(
                    (user.bio ?? '').trim().isEmpty ? 'No bio yet' : user.bio!.trim(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: (user.bio ?? '').trim().isEmpty ? const Color(0xFF8F98A3) : null,
                    ),
                  ),
                ),
              if (widget.controller.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  widget.controller.errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFFF7B7B),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.allowStartChat)
          TextButton.icon(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await widget.controller.createDirectChat(user.email);
              if (mounted) {
                navigator.pop();
              }
            },
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text('Open chat'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (widget.isCurrentUser)
          ElevatedButton(
            onPressed: _saving
                ? null
                : () async {
                    final navigator = Navigator.of(context);
                    setState(() => _saving = true);
                    final success = await widget.controller.updateMyProfile(
                      displayName: _displayNameController.text,
                      bio: _bioController.text,
                    );
                    if (!mounted) {
                      return;
                    }
                    setState(() => _saving = false);
                    if (success) {
                      navigator.pop();
                    }
                  },
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save profile'),
          ),
      ],
    );
  }
}

class _ProfileField extends StatelessWidget {
  const _ProfileField({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: const Color(0xFFCFD6DE),
              ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF121821),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF1D2631)),
          ),
          child: Text(value),
        ),
      ],
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.tile});

  final VoiceVideoTileModel tile;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFF121821)),
          lk.VideoTrackRenderer(
            tile.track,
            fit: tile.isScreenShare ? lk.VideoViewFit.contain : lk.VideoViewFit.cover,
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xB3121821),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF1D2631)),
                    ),
                    child: Text(
                      tile.user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ),
                if (tile.isScreenShare) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xB3121821),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF1D2631)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.screen_share_rounded,
                          size: 14,
                          color: Color(0xFFCFD6DE),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Screen',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: const Color(0xFFCFD6DE),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceRoomPanel extends StatelessWidget {
  const _VoiceRoomPanel({
    required this.controller,
    required this.chatTitle,
    required this.isGroupChat,
    required this.currentUserId,
    required this.canModerateParticipants,
    required this.state,
    required this.speakingUserIds,
    required this.onJoin,
    required this.onLeave,
    required this.onToggleMute,
    required this.onRefresh,
    required this.onSetMasterVolume,
    required this.onSetParticipantVolume,
    required this.onMuteParticipant,
    required this.onKickParticipant,
    required this.onToggleCamera,
    required this.onToggleScreenShare,
    required this.onOpenUserProfile,
  });

  final AppController controller;
  final String chatTitle;
  final bool isGroupChat;
  final String? currentUserId;
  final bool canModerateParticipants;
  final VoiceStateModel? state;
  final Set<String> speakingUserIds;
  final Future<void> Function() onJoin;
  final Future<void> Function() onLeave;
  final Future<void> Function() onToggleMute;
  final Future<void> Function() onRefresh;
  final Future<void> Function(double value) onSetMasterVolume;
  final Future<void> Function(String userId, double value) onSetParticipantVolume;
  final Future<void> Function(UserModel user) onMuteParticipant;
  final Future<void> Function(UserModel user) onKickParticipant;
  final Future<void> Function() onToggleCamera;
  final Future<void> Function() onToggleScreenShare;
  final Future<void> Function(UserModel user) onOpenUserProfile;

  Future<void> _openParticipantVolumeDialog(
    BuildContext context,
    VoiceParticipantModel participant,
    double initialValue,
  ) async {
    var currentValue = initialValue;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final percent = (currentValue * 100).round();
            return AlertDialog(
              title: Text('Volume for ${participant.user.displayName}'),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.volume_up_rounded,
                          size: 18,
                          color: Color(0xFF8F98A3),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: currentValue,
                            onChanged: (value) {
                              setState(() {
                                currentValue = value;
                              });
                              onSetParticipantVolume(participant.user.id, value);
                            },
                          ),
                        ),
                        Text(
                          '$percent%',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF8F98A3),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  IconData _connectionQualityIcon(String quality) {
    switch (quality) {
      case 'excellent':
        return Icons.signal_cellular_alt_rounded;
      case 'good':
        return Icons.signal_cellular_alt_2_bar_rounded;
      case 'poor':
        return Icons.signal_cellular_alt_1_bar_rounded;
      case 'lost':
        return Icons.signal_cellular_connected_no_internet_0_bar_rounded;
      default:
        return Icons.cell_tower_rounded;
    }
  }

  Color _connectionQualityColor(String quality) {
    switch (quality) {
      case 'excellent':
        return const Color(0xFF67D1A9);
      case 'good':
        return const Color(0xFFA7D66D);
      case 'poor':
        return const Color(0xFFFFC857);
      case 'lost':
        return const Color(0xFFFF7B7B);
      default:
        return const Color(0xFF8F98A3);
    }
  }

  String _connectionQualityLabel(String quality) {
    switch (quality) {
      case 'excellent':
        return 'Excellent';
      case 'good':
        return 'Good';
      case 'poor':
        return 'Poor';
      case 'lost':
        return 'Lost';
      default:
        return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final participants = state?.participants ?? const <VoiceParticipantModel>[];
    final isSelectedVoiceChat = controller.activeVoiceChatId == controller.selectedChatId;
    final inRoom = isSelectedVoiceChat &&
        (controller.voiceConnectionStatus == 'connected' ||
            controller.voiceConnectionStatus == 'reconnecting');
    final joinBusy = isSelectedVoiceChat && controller.voiceConnectionStatus == 'connecting';
    final voiceTitle = isGroupChat ? 'Voice room' : 'Voice call';
    final idleLabel = isGroupChat ? 'Room idle' : 'Call idle';
    final activeLabel = isGroupChat ? 'Room active' : 'Call active';
    final emptyLabel = isGroupChat ? 'Nobody is in voice right now' : 'Nobody is in the call right now';
    final joinLabel = isGroupChat ? 'Join voice' : 'Join call';
    final participantsLabel = isGroupChat ? '${participants.length} in voice' : '${participants.length} in call';
    final masterVolumePercent = (controller.voiceAudioSettings.masterVolume * 100).round();
    final videoTiles = inRoom ? controller.voiceVideoTiles : const <VoiceVideoTileModel>[];
    final screenShareUnavailableOnAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          voiceTitle,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          chatTitle,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF8F98A3),
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onRefresh,
                    tooltip: 'Refresh voice state',
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  Chip(
                    label: Text(
                      isSelectedVoiceChat
                          ? controller.voiceConnectionLabel()
                          : (state?.roomActive == true ? activeLabel : idleLabel),
                    ),
                  ),
                  Chip(
                    avatar: Icon(
                      switch (controller.voiceConnectionStatus) {
                        'connected' => Icons.network_check_rounded,
                        'connecting' => Icons.sync_rounded,
                        'reconnecting' => Icons.wifi_find_rounded,
                        'error' => Icons.portable_wifi_off_rounded,
                        _ => Icons.wifi_tethering_off_rounded,
                      },
                      size: 16,
                    ),
                    label: Text('Network ${controller.voiceConnectionLabel()}'),
                  ),
                  Chip(
                    avatar: const Icon(Icons.people_alt_outlined, size: 16),
                    label: Text(participantsLabel),
                  ),
                  Chip(
                    avatar: Icon(
                      controller.voiceMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      size: 16,
                    ),
                    label: Text(controller.voiceMuted ? 'Muted' : 'Mic on'),
                  ),
                ],
              ),
              if (inRoom) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onToggleCamera,
                      icon: Icon(
                        controller.voiceCameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                      ),
                      label: Text(controller.voiceCameraEnabled ? 'Camera on' : 'Camera off'),
                    ),
                    OutlinedButton.icon(
                      onPressed: screenShareUnavailableOnAndroid ? null : onToggleScreenShare,
                      icon: Icon(
                        controller.voiceScreenShareEnabled ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                      ),
                      label: Text(
                        screenShareUnavailableOnAndroid
                            ? 'Share unavailable'
                            : (controller.voiceScreenShareEnabled ? 'Stop sharing' : 'Share screen'),
                      ),
                    ),
                  ],
                ),
                if (screenShareUnavailableOnAndroid) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Android screen sharing is not configured in this build yet.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF8F98A3),
                        ),
                  ),
                ],
              ],
              if (videoTiles.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'Video',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final screenShareTiles = videoTiles.where((tile) => tile.isScreenShare).toList();
                    final cameraTiles = videoTiles.where((tile) => !tile.isScreenShare).toList();
                    final crossAxisCount = constraints.maxWidth >= 900
                        ? 3
                        : constraints.maxWidth >= 620
                            ? 2
                            : 1;
                    return Column(
                      children: [
                        for (final tile in screenShareTiles) ...[
                          AspectRatio(
                            aspectRatio: 16 / 10,
                            child: _VideoTile(tile: tile),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (cameraTiles.isNotEmpty)
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: cameraTiles.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: constraints.maxWidth < 620 ? 16 / 12 : 16 / 11,
                            ),
                            itemBuilder: (context, index) {
                              return _VideoTile(tile: cameraTiles[index]);
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121821),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF1D2631)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          'Sound settings',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          inRoom ? 'Reconnects voice when changed' : 'Applied on next join',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF8F98A3),
                              ),
                        ),
                        children: [
                          const SizedBox(height: 8),
                          SwitchListTile(
                            value: controller.voiceAudioSettings.echoCancellation,
                            onChanged: controller.setVoiceEchoCancellation,
                            title: const Text('Echo cancellation'),
                            subtitle: const Text('Reduce speaker echo picked up by the microphone'),
                            contentPadding: EdgeInsets.zero,
                          ),
                          SwitchListTile(
                            value: controller.voiceAudioSettings.noiseSuppression,
                            onChanged: controller.setVoiceNoiseSuppression,
                            title: const Text('Noise suppression'),
                            subtitle: const Text('Reduce background noise when possible'),
                            contentPadding: EdgeInsets.zero,
                          ),
                          SwitchListTile(
                            value: controller.voiceAudioSettings.autoGainControl,
                            onChanged: controller.setVoiceAutoGainControl,
                            title: const Text('Auto gain control'),
                            subtitle: const Text('Automatically level microphone loudness'),
                            contentPadding: EdgeInsets.zero,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(
                                Icons.volume_up_rounded,
                                size: 18,
                                color: Color(0xFF8F98A3),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Master volume',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              Text(
                                '$masterVolumePercent%',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF8F98A3),
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                          Slider(
                            value: controller.voiceAudioSettings.masterVolume,
                            onChanged: (value) => onSetMasterVolume(value),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Participants',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              if (participants.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    emptyLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF8F98A3),
                        ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: participants.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final participant = participants[index];
                    final isSelf = participant.user.id == currentUserId;
                    final speaking = speakingUserIds.contains(participant.user.id);
                    final qualityColor = _connectionQualityColor(participant.connectionQuality);
                    final participantVolume = controller.voiceParticipantVolumeForUser(participant.user.id);
                    final participantCard = InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => onOpenUserProfile(participant.user),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: speaking ? const Color(0xFF14251F) : const Color(0xFF121821),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: speaking ? const Color(0xFF2E8E6A) : const Color(0xFF1D2631),
                          ),
                        ),
                        child: Row(
                          children: [
                            CachedAvatar(
                              radius: 18,
                              label: participant.user.displayName,
                              imageUrl: participant.user.avatarUrl,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(participant.user.displayName),
                                      ),
                                      if (isSelf)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1D2631),
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            'You',
                                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                  color: const Color(0xFFCFD6DE),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    speaking ? 'Speaking now' : (participant.isMuted ? 'Muted' : 'Listening'),
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: speaking ? const Color(0xFF67D1A9) : const Color(0xFF8F98A3),
                                        ),
                                  ),
                                  if (participant.hasCamera || participant.isScreenSharing) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        if (participant.hasCamera)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1D2631),
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.videocam_rounded,
                                                  size: 12,
                                                  color: Color(0xFFCFD6DE),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'Camera',
                                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                        color: const Color(0xFFCFD6DE),
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (participant.isScreenSharing)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1D2631),
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.screen_share_rounded,
                                                  size: 12,
                                                  color: Color(0xFFCFD6DE),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'Screen',
                                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                        color: const Color(0xFFCFD6DE),
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _connectionQualityIcon(participant.connectionQuality),
                                      size: 16,
                                      color: qualityColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _connectionQualityLabel(participant.connectionQuality),
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: qualityColor,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                if (participant.pingMs != null || participant.packetLossPercent != null) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (participant.pingMs != null) '${participant.pingMs} ms',
                                      if (participant.packetLossPercent != null)
                                        '${participant.packetLossPercent!.toStringAsFixed(1)}%',
                                    ].join(' / '),
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: const Color(0xFF8F98A3),
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Icon(
                                  participant.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                  size: 18,
                                  color: participant.isMuted ? const Color(0xFF8F98A3) : const Color(0xFF67D1A9),
                                ),
                              ],
                            ),
                            if (!isSelf) ...[
                              const SizedBox(width: 8),
                              PopupMenuButton<String>(
                                tooltip: 'Participant actions',
                                onSelected: (value) {
                                  if (value == 'volume') {
                                    unawaited(
                                      _openParticipantVolumeDialog(context, participant, participantVolume),
                                    );
                                  } else if (value == 'mute') {
                                    onMuteParticipant(participant.user);
                                  } else if (value == 'kick') {
                                    onKickParticipant(participant.user);
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem<String>(
                                    value: 'volume',
                                    child: Text('Adjust volume'),
                                  ),
                                  if (canModerateParticipants)
                                    const PopupMenuItem<String>(
                                      value: 'mute',
                                      child: Text('Mute for everyone'),
                                    ),
                                  if (canModerateParticipants)
                                    const PopupMenuItem<String>(
                                      value: 'kick',
                                      child: Text('Remove from voice'),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                    return participantCard;
                  },
                ),
              if (controller.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  controller.errorMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFF7B7B),
                      ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: inRoom ? onToggleMute : null,
                icon: Icon(controller.voiceMuted ? Icons.mic_rounded : Icons.mic_off_rounded),
                label: Text(controller.voiceMuted ? 'Unmute' : 'Mute'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: inRoom
                  ? FilledButton.icon(
                      onPressed: onLeave,
                      icon: const Icon(Icons.call_end_rounded),
                      label: const Text('Leave'),
                    )
                  : FilledButton.icon(
                      onPressed: joinBusy ? null : onJoin,
                      icon: joinBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.graphic_eq_rounded),
                      label: Text(
                        controller.voiceConnectionStatus == 'reconnecting'
                            ? 'Reconnecting'
                            : (joinBusy ? 'Connecting' : joinLabel),
                      ),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

