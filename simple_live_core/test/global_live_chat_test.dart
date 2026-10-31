import 'dart:async';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'global_live_test.dart' show FakeAdapter, jsonBody;

class FakeSocket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final FakeSink sink = FakeSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSink implements WebSocketSink {
  final sent = <String>[];
  bool closed = false;
  @override
  void add(dynamic event) => sent.add(event.toString());
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final platform in ['youtube', 'twitch']) {
    test(
      '$platform discovery requires credentials, no blank fake list',
      () async {
        await expectLater(
          GlobalLiveSite(platform).getRecommendRooms(),
          throwsA(isA<GlobalLiveException>()),
        );
      },
    );
    test(
      '$platform discovery paginates with server cursors and caches',
      () async {
        final fake = FakeAdapter(
          (r) => platform == 'youtube'
              ? jsonBody({
                  'items': [
                    {
                      'id': {'videoId': 'abcdefgh_-1'},
                      'snippet': {
                        'title': 'Live',
                        'channelTitle': 'Channel',
                        'liveBroadcastContent': 'live',
                      },
                    },
                  ],
                  if (r.queryParameters['pageToken'] == null)
                    'nextPageToken': 'next',
                })
              : jsonBody({
                  'data': [
                    {
                      'user_login': 'channel',
                      'user_name': 'Channel',
                      'title': 'Live',
                      'viewer_count': 99,
                      'thumbnail_url': 'https://example.com/{width}x{height}',
                    },
                  ],
                  'pagination': {
                    if (r.queryParameters['after'] == null) 'cursor': 'next',
                  },
                }),
        );
        final config = GlobalLiveConfig()
          ..youtubeApiKey = 'test'
          ..twitchClientId = 'test'
          ..twitchAccessToken = 'test';
        final site = GlobalLiveSite(
          platform,
          config: config,
          http: Dio()..httpClientAdapter = fake,
        );
        expect((await site.getRecommendRooms()).items.single.title, 'Live');
        await site.getRecommendRooms();
        expect(fake.requests.length, 1);
        expect((await site.getRecommendRooms(page: 2)).hasMore, isFalse);
        expect(
          fake.requests.last.queryParameters[platform == 'youtube'
              ? 'pageToken'
              : 'after'],
          'next',
        );
        expect((await site.getRecommendRooms(page: 3)).items, isEmpty);
        expect(fake.requests.length, 2);
        if (platform == 'youtube') {
          expect(fake.requests.first.queryParameters['eventType'], 'live');
        } else {
          expect(fake.requests.first.headers['Authorization'], 'Bearer test');
        }
      },
    );
  }
  test(
    'YouTube chat keeps actual currency, server interval, removals and end state',
    () {
      final batch = GlobalChatBatch.fromYoutube({
        'nextPageToken': 'next',
        'pollingIntervalMillis': 45000,
        'offlineAt': '2026-10-31',
        'items': [
          {
            'id': 'sc',
            'authorDetails': {'displayName': 'Viewer'},
            'snippet': {
              'type': 'superChatEvent',
              'publishedAt': '2026-10-31T00:00:00Z',
              'superChatDetails': {
                'amountDisplayString': '€1.99',
                'amountMicros': '1990000',
                'currency': 'EUR',
                'userComment': 'Hello',
              },
            },
          },
          {
            'id': 'sticker',
            'snippet': {
              'type': 'superStickerEvent',
              'superStickerDetails': {
                'amountDisplayString': '¥100',
                'superStickerMetadata': {'altText': 'Thanks'},
              },
            },
          },
          {
            'snippet': {
              'type': 'messageDeletedEvent',
              'messageDeletedDetails': {'deletedMessageId': 'old'},
            },
          },
        ],
      });
      expect(batch.pollAfter, const Duration(seconds: 45));
      expect(batch.ended, isTrue);
      expect(batch.deletedIds, ['old']);
      final sc = batch.messages.first.data as LiveSuperChatMessage;
      expect(sc.priceDisplay, '€1.99');
      expect(sc.message, 'Hello');
      expect(sc.price, 0);
      expect(batch.messages.last.message, 'Thanks');
      expect(
        GlobalChatBatch.fromYoutube({'pollingIntervalMillis': 1000}).pollAfter,
        const Duration(seconds: 30),
      );
    },
  );
  test(
    'YouTube active chat ID and continuation reach the official endpoint',
    () async {
      final fake = FakeAdapter(
        (r) => r.path.endsWith('/videos')
            ? jsonBody({
                'items': [
                  {
                    'snippet': {
                      'title': 'Live',
                      'channelTitle': 'Host',
                      'liveBroadcastContent': 'live',
                    },
                    'liveStreamingDetails': {'activeLiveChatId': 'chat'},
                  },
                ],
              })
            : jsonBody({'items': [], 'nextPageToken': 'next'}),
      );
      final site = GlobalLiveSite(
        'youtube',
        config: GlobalLiveConfig()..youtubeApiKey = 'test',
        http: Dio()..httpClientAdapter = fake,
      );
      final detail = await site.getRoomDetail(roomId: 'abcdefgh_-1');
      await site.readYoutubeChat(detail, pageToken: 'previous');
      expect(
        fake.requests.last.path,
        'https://www.googleapis.com/youtube/v3/liveChat/messages',
      );
      expect(fake.requests.last.queryParameters['liveChatId'], 'chat');
      expect(fake.requests.last.queryParameters['pageToken'], 'previous');
    },
  );
  test(
    'Twitch tagged chat and Cheers keep Bits instead of invented currency',
    () {
      final message = TwitchReadOnlyChat.parseMessage(
        r'@id=one;display-name=Some\sName;bits=100 :host!host@host.tmi.twitch.tv PRIVMSG #channel :Cheer100 hello',
        'channel',
      )!;
      expect(message.userName, 'Some Name');
      expect(message.id, 'one');
      expect((message.data as LiveSuperChatMessage).priceDisplay, '100 Bits');
      expect(
        TwitchReadOnlyChat.parseMessage(
          ':host!u@host PRIVMSG #other :hello',
          'channel',
        ),
        isNull,
      );
      expect(
        TwitchReadOnlyChat.parseMessage(
          ':host!u@host PRIVMSG #channel :normal',
          'channel',
        )!.type,
        LiveMessageType.chat,
      );
    },
  );
  test('Twitch protocol receives, pongs, deletes and never sends chat', () async {
    final socket = FakeSocket();
    final chat = TwitchReadOnlyChat(
      connect: (uri) {
        expect(uri.scheme, 'wss');
        return socket;
      },
    );
    final messages = <LiveMessage>[];
    final deleted = <String?>[];
    chat.onMessage = messages.add;
    chat.onDelete = deleted.add;
    await chat.start(channel: 'channel', user: 'reader', token: 'read-token');
    socket.incoming.add(
      'PING :server\r\n@id=one :host!u@host PRIVMSG #channel :hello\r\n@target-msg-id=one :server CLEARMSG #channel :hello\r\n',
    );
    await Future<void>.delayed(Duration.zero);
    expect(messages.single.message, 'hello');
    expect(deleted, ['one']);
    expect(socket.sink.sent.any((s) => s.startsWith('PONG ')), isTrue);
    expect(socket.sink.sent.any((s) => s.startsWith('PRIVMSG')), isFalse);
    await chat.stop();
    expect(socket.sink.closed, isTrue);
    await socket.incoming.close();
  });
  test('Twitch rejects command injection before connecting', () async {
    var connected = false;
    final chat = TwitchReadOnlyChat(
      connect: (_) {
        connected = true;
        return FakeSocket();
      },
    );
    await chat.start(
      channel: 'channel',
      user: 'reader\r\nPRIVMSG',
      token: 'token',
    );
    expect(connected, isFalse);
  });
}
