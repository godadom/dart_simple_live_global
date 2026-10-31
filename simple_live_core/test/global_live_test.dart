import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  FakeAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  const video = 'abcdefgh_-1';
  const channel = 'UCabcdefghijklmnopqrstuv';
  group('strict global URL parsing', () {
    for (final url in [
      'https://youtube.com/watch?v=$video&t=1',
      'https://youtu.be/$video?si=x',
      'youtube.com/live/$video',
      'https://m.youtube.com/watch?v=$video',
    ]) {
      test(url, () => expect(LiveUrlParser.parse(url)?.roomId, video));
    }
    test('channel, handle and bare identifiers remain stable', () {
      expect(
        GlobalLiveLink.parse(channel, siteId: 'youtube')?.roomId,
        'channel/$channel',
      );
      expect(
        GlobalLiveLink.parse(
          'https://youtube.com/channel/$channel/live',
        )?.roomId,
        'channel/$channel',
      );
      expect(
        GlobalLiveLink.parse('https://youtube.com/@Example/live')?.roomId,
        '@Example',
      );
      expect(
        GlobalLiveLink.parse('@Example', siteId: 'youtube')?.url.toString(),
        'https://www.youtube.com/@Example/live',
      );
      expect(
        GlobalLiveLink.parse('Some_Name', siteId: 'twitch')?.roomId,
        'some_name',
      );
      expect(
        LiveUrlParser.parse('https://www.twitch.tv/Some_Name/')?.roomId,
        'some_name',
      );
    });
    for (final url in [
      'https://youtube.com.evil/watch?v=$video',
      'https://evil@youtube.com/watch?v=$video',
      'javascript://youtube.com/watch?v=$video',
      'https://twitch.tv/directory',
      'https://twitch.tv/name/videos',
      'https://youtube.com/watch?v=bad',
      'https://twitch.tv/a%2Fb',
      'https://youtube.com/shorts/$video',
      'https://youtube.com:444/watch?v=$video',
      'https://twitch.tv/%',
      'https://twitch.tv/%E0%A4%A',
      '',
    ]) {
      test('reject $url', () {
        expect(GlobalLiveLink.parse(url), isNull);
        expect(LiveUrlParser.parse(url), isNull);
      });
    }
    test(
      'reject cross-platform input',
      () => expect(
        GlobalLiveLink.parse('https://twitch.tv/example', siteId: 'youtube'),
        isNull,
      ),
    );
    test('old platform links still parse', () {
      for (final entry in {
        'live.bilibili.com/123': 'bilibili',
        'douyu.com/123': 'douyu',
        'huya.com/abc': 'huya',
        'live.douyin.com/123': 'douyin',
        'live.kuaishou.com/u/abc': 'kuaishou',
      }.entries) {
        expect(LiveUrlParser.parse(entry.key)?.siteId, entry.value);
      }
    });
  });
  test(
    'no credentials means unknown, never false live status or direct stream',
    () async {
      for (final platform in ['youtube', 'twitch']) {
        final site = GlobalLiveSite(platform);
        final id = platform == 'youtube' ? video : 'example';
        final detail = await site.getRoomDetail(roomId: id);
        expect(GlobalLiveSite.state(detail), GlobalLiveState.unknown);
        expect(
          site.getLiveStatus(roomId: id),
          throwsA(isA<GlobalLiveException>()),
        );
        expect(await site.getPlayQualites(detail: detail), isEmpty);
        expect((await site.searchRooms(id)).items.single.roomId, id);
      }
    },
  );
  for (final state in GlobalLiveState.values.where(
    (e) => e != GlobalLiveState.unknown && e != GlobalLiveState.offline,
  )) {
    test('YouTube $state and cache', () async {
      final fake = FakeAdapter(
        (request) => jsonBody({
          'items': [
            {
              'snippet': {
                'title': 'Title',
                'channelTitle': 'Streamer',
                'channelId': channel,
                'liveBroadcastContent': state == GlobalLiveState.live
                    ? 'live'
                    : state == GlobalLiveState.upcoming
                    ? 'upcoming'
                    : 'none',
              },
              if (state != GlobalLiveState.video)
                'liveStreamingDetails': {
                  if (state == GlobalLiveState.ended)
                    'actualEndTime': '2026-01-01',
                  'concurrentViewers': '42',
                },
            },
          ],
        }),
      );
      final site = GlobalLiveSite(
        'youtube',
        config: GlobalLiveConfig()..youtubeApiKey = 'test-key',
        http: Dio()..httpClientAdapter = fake,
      );
      final d = await site.getRoomDetail(roomId: video);
      expect(GlobalLiveSite.state(d), state);
      expect(d.status, state == GlobalLiveState.live);
      expect(d.data['channelId'], channel);
      await site.getRoomDetail(roomId: video);
      expect(fake.requests.length, 1);
    });
  }
  test(
    'YouTube handle resolves channel and offline without treating normal uploads as live',
    () async {
      final fake = FakeAdapter(
        (r) => jsonBody({
          'items': r.path.endsWith('/channels')
              ? [
                  {
                    'id': channel,
                    'snippet': {'title': 'Channel'},
                  },
                ]
              : [],
        }),
      );
      final site = GlobalLiveSite(
        'youtube',
        config: GlobalLiveConfig()..youtubeApiKey = 'test',
        http: Dio()..httpClientAdapter = fake,
      );
      final d = await site.getRoomDetail(roomId: '@Example');
      expect(d.roomId, '@Example');
      expect(GlobalLiveSite.state(d), GlobalLiveState.offline);
      expect(fake.requests.last.queryParameters['eventType'], 'live');
    },
  );
  for (final live in [true, false]) {
    test('Twitch live=$live with official headers', () async {
      final fake = FakeAdapter(
        (r) => jsonBody({
          'data': r.path.endsWith('/users')
              ? [
                  {
                    'display_name': 'Example',
                    'profile_image_url': 'https://example.com/avatar',
                  },
                ]
              : live
              ? [
                  {
                    'title': 'Game',
                    'viewer_count': 12,
                    'game_name': 'Chess',
                    'thumbnail_url': 'https://example.com/{width}x{height}',
                  },
                ]
              : [],
        }),
      );
      final config = GlobalLiveConfig()
        ..twitchClientId = 'test-client'
        ..twitchAccessToken = 'test-token';
      final site = GlobalLiveSite(
        'twitch',
        config: config,
        http: Dio()..httpClientAdapter = fake,
      );
      final d = await site.getRoomDetail(roomId: 'Example');
      expect(d.status, live);
      expect(d.roomId, 'example');
      expect(d.userName, 'Example');
      expect(fake.requests.first.headers['Authorization'], 'Bearer test-token');
      if (live) {
        expect(d.cover, 'https://example.com/640x360');
        expect(d.categoryName, 'Chess');
      }
    });
  }
  test('network timeout is redacted and does not become offline', () async {
    final fake = FakeAdapter(
      (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.receiveTimeout,
      ),
    );
    final site = GlobalLiveSite(
      'youtube',
      config: GlobalLiveConfig()..youtubeApiKey = 'PRIVATE',
      http: Dio()..httpClientAdapter = fake,
    );
    await expectLater(
      site.getLiveStatus(roomId: video),
      throwsA(
        isA<GlobalLiveException>().having(
          (e) => e.message,
          'message',
          contains('网络'),
        ),
      ),
    );
  });
  test('malformed metadata is an explicit query failure', () async {
    final fake = FakeAdapter(
      (request) => jsonBody({
        'items': [
          {'snippet': null},
        ],
      }),
    );
    final site = GlobalLiveSite(
      'youtube',
      config: GlobalLiveConfig()..youtubeApiKey = 'test',
      http: Dio()..httpClientAdapter = fake,
    );
    await expectLater(
      site.getLiveStatus(roomId: video),
      throwsA(
        isA<GlobalLiveException>().having(
          (e) => e.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
  });
  for (final code in [401, 403, 429, 500]) {
    test('API error $code is explicit and does not leak credentials', () async {
      final fake = FakeAdapter((r) => jsonBody({}, code));
      final site = GlobalLiveSite(
        'youtube',
        config: GlobalLiveConfig()..youtubeApiKey = 'PRIVATE',
        http: Dio()..httpClientAdapter = fake,
      );
      await expectLater(
        site.getRoomDetail(roomId: video),
        throwsA(
          isA<GlobalLiveException>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
      await expectLater(
        site.getLiveStatus(roomId: video),
        throwsA(isA<GlobalLiveException>()),
      );
      expect(fake.requests.length, code == 403 || code == 429 ? 1 : 2);
    });
  }
}
