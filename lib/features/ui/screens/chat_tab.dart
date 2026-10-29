import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Representation of a single message in the chat thread
class ChatMessage {
  final String id;
  final bool isUser;
  String text;
  final DateTime timestamp;
  final Map<String, dynamic>? toolData;
  final bool isError;

  ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.toolData,
    this.isError = false,
  });
}

/// Dedicated, uncluttered text chat tab for Device Assistant
class ChatTab extends StatefulWidget {
  final List<ChatMessage> messages;
  final Future<void> Function(String text) onSendMessage;
  final bool isLiveConnected;
  final VoidCallback? onToggleLive;
  final VoidCallback? onClearChat;
  final Future<void> Function(String toolName, Map<String, dynamic> args)?
      onDispatchTool;

  const ChatTab({
    super.key,
    required this.messages,
    required this.onSendMessage,
    this.isLiveConnected = false,
    this.onToggleLive,
    this.onClearChat,
    this.onDispatchTool,
  });

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _isSending = false;

  final List<String> _quickSuggestions = [
    'System status',
    'Take a screenshot',
    'List memories',
    'Scroll down',
    'Go home',
    'Show recents',
  ];

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend([String? presetText]) async {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty || _isSending) return;

    if (presetText == null) {
      _textController.clear();
    }

    setState(() => _isSending = true);
    try {
      await widget.onSendMessage(text);
      _scrollToBottom();
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Auto-scroll on new messages
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Column(
      children: [
        // Top status & utility bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            border: Border(
              bottom:
                  BorderSide(color: theme.dividerColor.withValues(alpha: 0.2)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 18,
                color: widget.isLiveConnected ? Colors.cyanAccent : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                widget.isLiveConnected
                    ? 'Connected to Gemini 3.8 Live'
                    : 'Device Assistant Chat (Idle)',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              if (widget.messages.isNotEmpty && widget.onClearChat != null)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  tooltip: 'Clear Chat History',
                  onPressed: widget.onClearChat,
                ),
              if (widget.onToggleLive != null)
                IconButton(
                  icon: Icon(
                    widget.isLiveConnected ? Icons.mic : Icons.mic_none,
                    size: 20,
                    color: widget.isLiveConnected
                        ? Colors.cyanAccent
                        : Colors.grey,
                  ),
                  tooltip: widget.isLiveConnected
                      ? 'Disconnect Voice'
                      : 'Connect Voice (Gemini Live)',
                  onPressed: widget.onToggleLive,
                ),
            ],
          ),
        ),

        // Message Thread Area
        Expanded(
          child: widget.messages.isEmpty
              ? _buildEmptyState(theme)
              : ListView.builder(
                  controller: _scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  itemCount: widget.messages.length,
                  itemBuilder: (ctx, idx) =>
                      _buildMessageBubble(widget.messages[idx], theme),
                ),
        ),

        // Quick Suggestion Chips (when idle)
        if (widget.messages.isEmpty)
          Container(
            height: 44,
            margin: const EdgeInsets.only(bottom: 6),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              itemCount: _quickSuggestions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, idx) {
                final suggestion = _quickSuggestions[idx];
                return ActionChip(
                  label: Text(suggestion, style: const TextStyle(fontSize: 12)),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  side: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.3)),
                  onPressed: () => _handleSend(suggestion),
                );
              },
            ),
          ),

        // Bottom Text Input Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _handleSend(),
                    decoration: InputDecoration(
                      hintText: 'Type a command or ask assistant...',
                      hintStyle:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.4)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: Colors.cyanAccent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.indigoAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _isSending ? null : () => _handleSend(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.indigoAccent.withValues(alpha: 0.12),
                border: Border.all(
                    color: Colors.indigoAccent.withValues(alpha: 0.3)),
              ),
              child: const Icon(Icons.chat_bubble_outline,
                  size: 32, color: Colors.indigoAccent),
            ),
            const SizedBox(height: 16),
            const Text(
              'How can I help you today?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Send natural language queries or direct device commands.\nAutomate tasks, take screenshots, remember facts, or control apps.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, ThemeData theme) {
    // Tool execution notice bubble
    if (msg.toolData != null) {
      final tool = msg.toolData!['tool'] ?? 'device_tool';
      final isBlocked = msg.toolData!['status'] == 'blocked';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isBlocked
              ? Colors.red.withValues(alpha: 0.12)
              : Colors.indigo.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isBlocked
                ? Colors.redAccent.withValues(alpha: 0.3)
                : Colors.indigoAccent.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isBlocked ? Icons.block : Icons.build_circle_outlined,
              size: 16,
              color: isBlocked ? Colors.redAccent : Colors.cyanAccent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Device Tool: $tool',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isBlocked ? Colors.redAccent : Colors.cyanAccent,
                    ),
                  ),
                  if (msg.toolData!['args'] != null)
                    Text(
                      'Args: ${msg.toolData!['args']}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ),
            if (tool == 'remember' &&
                !isBlocked &&
                widget.onDispatchTool != null)
              TextButton(
                onPressed: () => widget.onDispatchTool!('undo_last', {}),
                child: const Text('Undo',
                    style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
              ),
          ],
        ),
      );
    }

    final isUser = msg.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? Colors.indigo.shade700
              : theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.7),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: Border.all(
            color: isUser
                ? Colors.indigoAccent.withValues(alpha: 0.4)
                : theme.dividerColor.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            SelectableText(
              msg.text,
              style: TextStyle(
                fontSize: 13.5,
                color: isUser ? Colors.white : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(msg.timestamp),
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                ),
                if (!isUser) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: msg.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: const Icon(Icons.copy, size: 12, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
