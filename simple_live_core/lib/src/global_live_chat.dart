import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'model/live_message.dart';

class GlobalChatBatch {
  final List<LiveMessage> messages;
  final List<String> deletedIds;
  final bool clear;
  final String? nextPageToken;
  final Duration pollAfter;
  final bool ended;
  GlobalChatBatch({
    required this.messages,
    this.deletedIds = const [],
    this.clear = false,
    this.nextPageToken,
    this.pollAfter = const Duration(seconds: 30),
    this.ended = false,
  });

  factory GlobalChatBatch.fromYoutube(Map<String, dynamic> json) {
    final messages = <LiveMessage>[];
    final deleted = <String>[];
    var clear = false;
    for (final item in json['items'] as List? ?? []) {
      final snippet = item['snippet'];
      final type = snippet['type'];
      if (type == 'messageDeletedEvent') {
        final id = '${snippet['messageDeletedDetails']?['deletedMessageId']}';
        deleted.add(id);
        messages.removeWhere((message) => message.id == id);
        continue;
      }
      if (type == 'userBannedEvent') {
        clear = true;
        messages.clear();
        continue;
      }
      if (!{
        'textMessageEvent',
        'superChatEvent',
        'superStickerEvent',
      }.contains(type)) {
        continue;
      }
      final author = item['authorDetails'] ?? {};
      final published =
          DateTime.tryParse('${snippet['publishedAt']}') ?? DateTime.now();
      final paid =
          snippet['superChatDetails'] ?? snippet['superStickerDetails'];
      final text =
          paid?['userComment'] ??
          paid?['superStickerMetadata']?['altText'] ??
          snippet['displayMessage'] ??
          '';
      final sc = paid == null
          ? null
          : LiveSuperChatMessage(
              id: item['id'],
              userName: author['displayName'] ?? '',
              face: author['profileImageUrl'] ?? '',
              message: text,
              price: 0,
              priceDisplay: paid['amountDisplayString'] ?? paid['currency'],
              startTime: published,
              endTime: published,
              backgroundColor: '#ffeb99',
              backgroundBottomColor: '#8a5b00',
            );
      messages.add(
        LiveMessage(
          id: item['id'],
          type: sc == null ? LiveMessageType.chat : LiveMessageType.superChat,
          userName: author['displayName'] ?? '',
          message: text,
          data: sc,
          color: LiveMessageColor.white,
        ),
      );
    }
    return GlobalChatBatch(
      messages: messages,
      deletedIds: deleted,
      clear: clear,
      nextPageToken: json['nextPageToken'],
      ended: json['offlineAt'] != null,
      // Respect the server interval, with a conservative quota-saving floor.
      pollAfter: Duration(
        milliseconds: (json['pollingIntervalMillis'] as int? ?? 30000).clamp(
          30000,
          1 << 30,
        ),
      ),
    );
  }
}

/// Twitch IRC receive-only adapter. Never exposes a chat-send operation.
class TwitchReadOnlyChat {
  final WebSocketChannel Function(Uri) _connect;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  int _generation = 0;
  String _buffer = '';
  void Function(LiveMessage)? onMessage;
  void Function(String)? onStatus;
  void Function(String?)? onDelete;
  TwitchReadOnlyChat({WebSocketChannel Function(Uri)? connect})
    : _connect = connect ?? WebSocketChannel.connect;

  Future<void> start({
    required String channel,
    required String user,
    required String token,
  }) async {
    await stop();
    final generation = _generation;
    final name = RegExp(r'^[a-z0-9_]{1,25}$');
    if (!name.hasMatch(channel) ||
        !name.hasMatch(user) ||
        token.isEmpty ||
        RegExp(r'\s').hasMatch(token)) {
      onStatus?.call(
        '请配置 Twitch 聊天用户名及 chat:read 用户令牌；App Access Token 不能用于聊天',
      );
      return;
    }
    try {
      final socket = _connect(Uri.parse('wss://irc-ws.chat.twitch.tv:443'));
      _socket = socket;
      await socket.ready.timeout(const Duration(seconds: 10));
      if (generation != _generation) {
        await socket.sink.close();
        return;
      }
      _subscription = socket.stream.listen(
        (data) {
          if (generation != _generation) return;
          _buffer += data.toString();
          if (_buffer.length > 131072) {
            onStatus?.call('聊天消息过大，连接已关闭');
            unawaited(stop());
            return;
          }
          while (_buffer.contains('\r\n')) {
            final end = _buffer.indexOf('\r\n');
            final line = _buffer.substring(0, end);
            _buffer = _buffer.substring(end + 2);
            if (line.startsWith('PING ')) {
              socket.sink.add('PONG ${line.substring(5)}\r\n');
              continue;
            }
            if (line.contains(' 001 ')) {
              onStatus?.call('聊天服务器连接成功');
            }
            if (line.contains(' NOTICE ') || line.contains(' RECONNECT')) {
              onStatus?.call('聊天连接被平台拒绝或中断，请检查令牌与权限后重新连接');
              unawaited(stop());
              return;
            }
            if (line.contains(' CLEARMSG ')) {
              onDelete?.call(_tags(line)['target-msg-id']);
            }
            if (line.contains(' CLEARCHAT ')) onDelete?.call(null);
            final message = parseMessage(line, channel);
            if (message != null) onMessage?.call(message);
          }
        },
        onError: (_) {
          if (generation != _generation) return;
          onStatus?.call('聊天网络错误，请重试');
          unawaited(stop());
        },
        onDone: () {
          if (generation == _generation) onStatus?.call('聊天连接已关闭，请重试');
        },
      );
      // Only protocol negotiation/authentication/subscription and PONG are sent.
      socket.sink.add(
        'PASS oauth:${token.replaceFirst(RegExp(r"^oauth:"), "")}\r\n',
      );
      socket.sink.add('NICK $user\r\n');
      socket.sink.add('CAP REQ :twitch.tv/tags twitch.tv/commands\r\n');
      socket.sink.add('JOIN #$channel\r\n');
    } catch (_) {
      if (generation == _generation) {
        onStatus?.call('聊天连接失败，请检查网络后重试');
        await stop();
      }
    }
  }

  static String _unescape(String value) {
    final result = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (value[i] == r'\' && i + 1 < value.length) {
        final code = value[++i];
        result.write(
          {'s': ' ', ':': ';', 'r': '\r', 'n': '\n', r'\': r'\'}[code] ?? code,
        );
      } else {
        result.write(value[i]);
      }
    }
    return result.toString();
  }

  static Map<String, String> _tags(String line) {
    if (!line.startsWith('@')) return {};
    return {
      for (final field in line.substring(1, line.indexOf(' ')).split(';'))
        field.split('=').first: field.contains('=')
            ? _unescape(field.substring(field.indexOf('=') + 1))
            : '',
    };
  }

  static LiveMessage? parseMessage(String line, String channel) {
    final match = RegExp(
      r'(?:^| ):(\w+)!\S+ PRIVMSG #(\w+) :(.*)$',
    ).firstMatch(line);
    if (match == null || match[2] != channel) return null;
    final tags = _tags(line);
    final bits = int.tryParse(tags['bits'] ?? '') ?? 0;
    final time = DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(tags['tmi-sent-ts'] ?? '') ??
          DateTime.now().millisecondsSinceEpoch,
    );
    final user = tags['display-name']?.isNotEmpty == true
        ? tags['display-name']!
        : match[1]!;
    final message = match[3]!;
    return LiveMessage(
      id: tags['id'],
      type: bits > 0 ? LiveMessageType.superChat : LiveMessageType.chat,
      userName: user,
      message: message,
      color: LiveMessageColor.white,
      data: bits <= 0
          ? null
          : LiveSuperChatMessage(
              id: tags['id'],
              userName: user,
              face: '',
              message: message,
              price: 0,
              priceDisplay: '$bits Bits',
              startTime: time,
              endTime: time,
              backgroundColor: '#e4d5ff',
              backgroundBottomColor: '#6441a5',
            ),
    );
  }

  Future<void> stop() async {
    _generation++;
    _buffer = '';
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await socket?.sink.close();
    } catch (_) {}
  }
}
