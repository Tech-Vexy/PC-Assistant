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
/// Powered by NVIDIA Nemotron on Nebius Token Factory with real-time tool calling.
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
    'List memories',
    'Take a screenshot',
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
                Icons.psychology,
                size: 20,
                color: widget.isLiveConnected
                    ? Colors.cyanAccent
                    : Colors.tealAccent,
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NVIDIA Nemotron Agent',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    widget.isLiveConnected
                        ? 'Device STT: Listening on-device...'
                        : 'Nebius Token Factory | STT Ready',
                    style: TextStyle(
                      fontSize: 10,
                      color: widget.isLiveConnected
                          ? Colors.greenAccent
                          : Colors.grey.shade400,
                    ),
                  ),
                ],
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
                      ? 'Stop Device STT'
                      : 'Start Device STT',
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

        // Quick Suggestion Chips (when idle or list empty)
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
                      hintText: 'Ask or command Nemotron...',
                      hintStyle:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.4)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _isSending
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.send_rounded,
                            size: 20, color: Colors.cyanAccent),
                        onPressed: () => _handleSend(),
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
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.indigo.withValues(alpha: 0.15),
                border: Border.all(
                    color: Colors.indigoAccent.withValues(alpha: 0.3)),
              ),
              child: const Icon(
                Icons.psychology,
                size: 48,
                color: Colors.cyanAccent,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'NVIDIA Nemotron On-Device Agent',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              'Type a command, ask factual queries, or tap the microphone to use continuous on-device speech recognition.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, ThemeData theme) {
    // Tool execution notice bubble with rich real-result breakdown
    if (msg.toolData != null) {
      final tool = msg.toolData!['tool'] ?? 'device_tool';
      final isBlocked = msg.toolData!['status'] == 'blocked';
      final result = (msg.toolData!['result'] as Map<dynamic, dynamic>?)
              ?.cast<String, dynamic>() ??
          {};

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isBlocked ? Icons.block : Icons.build_circle_outlined,
                  size: 16,
                  color: isBlocked ? Colors.redAccent : Colors.cyanAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Device Tool: $tool',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isBlocked ? Colors.redAccent : Colors.cyanAccent,
                    ),
                  ),
                ),
                if (tool == 'remember' &&
                    !isBlocked &&
                    widget.onDispatchTool != null)
                  TextButton(
                    onPressed: () => widget.onDispatchTool!('undo_last', {}),
                    child: const Text('Undo',
                        style:
                            TextStyle(fontSize: 11, color: Colors.amberAccent)),
                  ),
              ],
            ),
            if (msg.toolData!['args'] != null &&
                (msg.toolData!['args'] as Map).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  'Args: ${msg.toolData!['args']}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 4),
            _buildToolResultContent(result, theme),
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

  Widget _buildToolResultContent(Map<String, dynamic> result, ThemeData theme) {
    if (result.isEmpty) {
      return const Text('Action executed successfully.',
          style: TextStyle(fontSize: 11, color: Colors.greenAccent));
    }
    if (result.containsKey('error')) {
      return Text('Error: ${result['error']}',
          style: const TextStyle(fontSize: 11, color: Colors.redAccent));
    }
    if (result.containsKey('blocked') || result['status'] == 'blocked') {
      return Text(
        'Blocked by Security Shield: ${result['security_alert'] ?? result['reason'] ?? 'Sensitive application active'}',
        style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
      );
    }
    if (result.containsKey('os')) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _buildInfoChip(Icons.desktop_windows,
              '${result['os']} ${result['os_version'] ?? ''}'),
          _buildInfoChip(Icons.memory, '${result['cores'] ?? 1} cores'),
          _buildInfoChip(Icons.devices, '${result['device'] ?? 'Mobile'}'),
        ],
      );
    }
    if (result.containsKey('memories')) {
      final list = result['memories'] as List<dynamic>? ?? [];
      if (list.isEmpty) {
        return const Text('No memories stored in database.',
            style: TextStyle(fontSize: 11, color: Colors.grey));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: list.take(5).map((m) {
          final map = m is Map ? m : {'key': 'key', 'value': m.toString()};
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Text(
              '• ${map['key']}: ${map['value']}',
              style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
            ),
          );
        }).toList(),
      );
    }
    if (result.containsKey('answer')) {
      return Text('${result['answer']}',
          style: const TextStyle(fontSize: 11, color: Colors.white70));
    }
    if (result.containsKey('steps')) {
      final steps = result['steps'] as List<dynamic>? ?? [];
      return Text(
        'Plan generated with ${steps.length} steps for: "${result['goal'] ?? ''}"',
        style: const TextStyle(fontSize: 11, color: Colors.greenAccent),
      );
    }
    if (result.containsKey('format') && result['format'] == 'image/jpeg') {
      return Text('Screenshot captured (${result['size_bytes'] ?? 0} bytes)',
          style: const TextStyle(fontSize: 11, color: Colors.greenAccent));
    }
    if (result.containsKey('status')) {
      return Text('Status: ${result['status']}',
          style: const TextStyle(fontSize: 11, color: Colors.greenAccent));
    }
    return Text(result.toString(),
        style: const TextStyle(fontSize: 11, color: Colors.grey));
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.cyanAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.cyanAccent),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(fontSize: 10, color: Colors.cyanAccent)),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
