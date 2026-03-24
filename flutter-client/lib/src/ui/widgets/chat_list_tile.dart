import 'package:flutter/material.dart';

import 'cached_network_media.dart';

class ChatListTile extends StatelessWidget {
  const ChatListTile({
    super.key,
    required this.title,
    required this.preview,
    required this.meta,
    required this.avatarLabel,
    this.avatarUrl,
    required this.unreadCount,
    required this.notificationsEnabled,
    required this.selected,
    required this.onTap,
    this.isOnline = false,
    this.typingText,
  });

  final String title;
  final String preview;
  final String meta;
  final String avatarLabel;
  final String? avatarUrl;
  final int unreadCount;
  final bool notificationsEnabled;
  final bool selected;
  final VoidCallback onTap;
  final bool isOnline;
  final String? typingText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? const Color(0xFF171D26) : const Color(0xFF121821),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? const Color(0xFF313A46)
                  : unreadCount > 0
                        ? const Color(0xFF495567)
                        : const Color(0xFF1D2631),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(label: avatarLabel, imageUrl: avatarUrl, isOnline: isOnline),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          meta,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF8F98A3),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: typingText != null
                              ? Text(
                                  typingText!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: const Color(0xFF67D1A9),
                                    fontWeight: FontWeight.w500,
                                  ),
                                )
                              : Text(
                                  preview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: const Color(0xFF8F98A3),
                                  ),
                                ),
                        ),
                        if (unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: notificationsEnabled
                                  ? const Color(0xFFF5F7FB)
                                  : const Color(0xFF4B5563),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : '$unreadCount',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: notificationsEnabled
                                    ? const Color(0xFF0B0D10)
                                    : const Color(0xFFE6EDF5),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.label,
    this.imageUrl,
    this.isOnline = false,
  });

  final String label;
  final String? imageUrl;
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final firstLetter = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CachedAvatar(
          radius: 20,
          label: firstLetter,
          imageUrl: imageUrl,
        ),
        if (isOnline)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: const Color(0xFF57D18C),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF121821),
                  width: 2.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
