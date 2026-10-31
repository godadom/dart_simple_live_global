import 'package:dio/dio.dart';
import '../simple_live_core.dart';

enum GlobalLiveState { unknown, live, offline, upcoming, ended, video }

/// Optional, session-only credentials. Never included in backups or logs.
class GlobalLiveConfig {
  String youtubeApiKey = '';
  String twitchClientId = '';
  String twitchAccessToken = '';
  String twitchEmbedPage = '';
  String twitchChatUser = '';
  String twitchChatToken = ''; // Optional User Access Token, chat:read only.
}

class GlobalLiveException implements Exception {
  final String message;
  const GlobalLiveException(this.message);
  @override
  String toString() => message;
}

/// Official metadata APIs only. Playback stays with the official player.
class GlobalLiveSite extends LiveSite {
  final GlobalLiveConfig config;
  final Dio _http;
  final _cache = <String, (DateTime, LiveRoomDetail)>{};
  DateTime? _retryAfter;
  final _listingPages = <int, LiveCategoryResult>{};
  final _listingTokens = <int, String>{};
  DateTime? _listingAt;
  GlobalLiveSite(String platform, {GlobalLiveConfig? config, Dio? http})
    : config = config ?? GlobalLiveConfig(),
      _http =
          http ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ),
          ) {
    if (!{'youtube', 'twitch'}.contains(platform)) {
      throw ArgumentError.value(platform);
    }
    id = platform;
    name = platform == 'youtube' ? 'YouTube Live' : 'Twitch';
  }

  void clearCache() {
    _cache.clear();
    _listingPages.clear();
    _listingTokens.clear();
    _listingAt = null;
    _retryAfter = null;
  }

  GlobalLiveLink link(String input) =>
      GlobalLiveLink.parse(input, siteId: id) ??
      (throw const GlobalLiveException(
        '请输入有效的直播链接、频道 ID / Handle 或 Twitch 频道名称',
      ));
  bool get configured => id == 'youtube'
      ? config.youtubeApiKey.isNotEmpty
      : config.twitchClientId.isNotEmpty && config.twitchAccessToken.isNotEmpty;
  static GlobalLiveState state(LiveRoomDetail detail) => detail.data is Map
      ? (detail.data['state'] as GlobalLiveState? ?? GlobalLiveState.unknown)
      : GlobalLiveState.unknown;

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query,
  ) async {
    if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) {
      throw const GlobalLiveException('平台限流或配额不足，请稍后重试');
    }
    try {
      final response = await _http.get<Map<String, dynamic>>(
        id == 'youtube'
            ? 'https://www.googleapis.com/youtube/v3/$path'
            : 'https://api.twitch.tv/helix/$path',
        queryParameters: {
          ...query,
          if (id == 'youtube') 'key': config.youtubeApiKey,
        },
        options: Options(
          headers: id == 'twitch'
              ? {
                  'Client-Id': config.twitchClientId,
                  'Authorization': 'Bearer ${config.twitchAccessToken}',
                }
              : null,
        ),
      );
      return response.data!;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (path == 'liveChat/messages' && code == 403) {
        final body = e.response?.data;
        final errorBody = body is Map ? body['error'] : null;
        final errors = errorBody is Map ? errorBody['errors'] : null;
        final reason = errors is List && errors.isNotEmpty
            ? errors.first['reason']
            : null;
        if (reason == 'liveChatDisabled') {
          throw const GlobalLiveException('主播已关闭直播聊天');
        }
        if (reason == 'liveChatEnded') {
          throw const GlobalLiveException('直播聊天已结束');
        }
        if (reason == 'forbidden') {
          throw const GlobalLiveException('当前凭据无权读取该直播聊天');
        }
      }
      if (code == 429 || code == 403) {
        _retryAfter = DateTime.now().add(const Duration(minutes: 5));
        throw const GlobalLiveException('平台限流、配额耗尽或访问被拒绝；请检查配置，5 分钟后重试');
      }
      if (code == 401) throw const GlobalLiveException('API 凭据无效或已过期，请重新配置');
      // Never expose DioException: it contains tokens and API keys.
      throw const GlobalLiveException('官方 API 查询失败，请检查网络后重试');
    } catch (_) {
      throw const GlobalLiveException('官方 API 返回了无法识别的数据');
    }
  }

  LiveRoomDetail _detail(
    GlobalLiveLink target, {
    GlobalLiveState state = GlobalLiveState.unknown,
    String? title,
    String? user,
    String avatar = '',
    String cover = '',
    int online = 0,
    String? videoId,
    String? channelId,
    String? category,
    String? liveChatId,
  }) => LiveRoomDetail(
    roomId: target.roomId,
    title: title ?? target.roomId,
    cover: cover,
    userName: user ?? target.roomId,
    userAvatar: avatar,
    online: online,
    status: state == GlobalLiveState.live,
    url: target.url.toString(),
    isRecord: state == GlobalLiveState.video || state == GlobalLiveState.ended,
    categoryName: category,
    data: {
      'state': state,
      'videoId': videoId,
      'channelId': channelId,
      'liveChatId': liveChatId,
    },
    notice: state == GlobalLiveState.unknown
        ? '状态未知：未配置官方 API，仍可打开官方播放器；不会将未知状态当作离线'
        : null,
  );

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final target = link(roomId);
    if (!configured) {
      return _detail(target, videoId: target.isVideo ? target.roomId : null);
    }
    final cached = _cache[target.roomId];
    if (cached != null &&
        DateTime.now().difference(cached.$1) <
            Duration(minutes: id == 'youtube' && !target.isVideo ? 15 : 2)) {
      return cached.$2;
    }
    try {
      final result = id == 'youtube'
          ? await _youtube(target)
          : await _twitch(target);
      _cache[target.roomId] = (DateTime.now(), result);
      return result;
    } on GlobalLiveException {
      rethrow;
    } catch (_) {
      throw const GlobalLiveException('官方 API 返回了无法识别的数据');
    }
  }

  String _thumb(dynamic snippet) =>
      snippet?['thumbnails']?['high']?['url']?.toString() ??
      snippet?['thumbnails']?['default']?['url']?.toString() ??
      '';
  Future<LiveRoomDetail> _youtube(GlobalLiveLink target) async {
    String? videoId = target.isVideo ? target.roomId : null;
    String? channelId;
    String? user;
    String avatar = '';
    if (!target.isVideo) {
      final channels = await _get('channels', {
        'part': 'snippet',
        if (target.roomId.startsWith('@'))
          'forHandle': target.roomId
        else
          'id': target.roomId.substring(8),
      });
      final items = channels['items'] as List;
      if (items.isEmpty) throw const GlobalLiveException('未找到 YouTube 频道');
      channelId = items.first['id'];
      user = items.first['snippet']['title'];
      avatar = _thumb(items.first['snippet']);
      final live = await _get('search', {
        'part': 'id',
        'channelId': channelId,
        'type': 'video',
        'eventType': 'live',
        'maxResults': 1,
      });
      final videos = live['items'] as List;
      if (videos.isEmpty) {
        return _detail(
          target,
          state: GlobalLiveState.offline,
          user: user,
          avatar: avatar,
          channelId: channelId,
          title: '频道当前未开播',
        );
      }
      videoId = videos.first['id']['videoId'];
    }
    final videos = await _get('videos', {
      'part': 'snippet,liveStreamingDetails,status',
      'id': videoId,
    });
    final items = videos['items'] as List;
    if (items.isEmpty) throw const GlobalLiveException('视频不存在、已删除或不可公开访问');
    final video = items.first;
    final snippet = video['snippet'];
    final live = video['liveStreamingDetails'];
    final state = live?['actualEndTime'] != null
        ? GlobalLiveState.ended
        : snippet['liveBroadcastContent'] == 'live'
        ? GlobalLiveState.live
        : snippet['liveBroadcastContent'] == 'upcoming'
        ? GlobalLiveState.upcoming
        : GlobalLiveState.video;
    return _detail(
      target,
      state: state,
      title: snippet['title'],
      user: snippet['channelTitle'],
      channelId: snippet['channelId'],
      avatar: avatar,
      cover: _thumb(snippet),
      online: int.tryParse('${live?['concurrentViewers']}') ?? 0,
      videoId: videoId,
      liveChatId: live?['activeLiveChatId'],
    );
  }

  Future<LiveRoomDetail> _twitch(GlobalLiveLink target) async {
    final users = await _get('users', {'login': target.roomId});
    final items = users['data'] as List;
    if (items.isEmpty) throw const GlobalLiveException('未找到 Twitch 频道');
    final user = items.first;
    final streams = await _get('streams', {'user_login': target.roomId});
    final data = streams['data'] as List;
    final stream = data.isEmpty ? null : data.first;
    return _detail(
      target,
      state: stream == null ? GlobalLiveState.offline : GlobalLiveState.live,
      title: stream?['title'] ?? '频道当前未开播',
      user: user['display_name'],
      avatar: user['profile_image_url'] ?? '',
      cover:
          (stream?['thumbnail_url'] as String? ??
                  user['offline_image_url'] as String? ??
                  '')
              .replaceAll('{width}', '640')
              .replaceAll('{height}', '360'),
      online: stream?['viewer_count'] ?? 0,
      category: stream?['game_name'],
    );
  }

  void _requireApi() {
    if (!configured) {
      throw const GlobalLiveException('请先在平台设置中配置官方 API，以加载直播列表和元数据');
    }
  }

  /// Public live discovery, never an account's personalised recommendation feed.
  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    _requireApi();
    if (_listingAt != null &&
        DateTime.now().difference(_listingAt!) > const Duration(minutes: 5)) {
      _listingPages.clear();
      _listingTokens.clear();
      _listingAt = null;
    }
    if (_listingPages.containsKey(page)) return _listingPages[page]!;
    if (page > 20) return LiveCategoryResult(hasMore: false, items: []);
    final cursor = _listingTokens[page];
    if (page > 1 && cursor == null) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    final response = await _get(id == 'youtube' ? 'search' : 'streams', {
      if (id == 'youtube') ...{
        'part': 'snippet',
        'type': 'video',
        'eventType': 'live',
        'order': 'viewCount',
        'maxResults': 24,
        if (cursor != null) 'pageToken': cursor,
      } else ...{
        'first': 24,
        'type': 'live',
        if (cursor != null) 'after': cursor,
      },
    });
    final items = <LiveRoomItem>[];
    if (id == 'youtube') {
      for (final item in response['items'] as List) {
        final snippet = item['snippet'];
        if (snippet['liveBroadcastContent'] != 'live') continue;
        items.add(
          LiveRoomItem(
            roomId: item['id']['videoId'],
            title: snippet['title'],
            cover: _thumb(snippet),
            userName: snippet['channelTitle'],
          ),
        );
      }
    } else {
      for (final item in response['data'] as List) {
        items.add(
          LiveRoomItem(
            roomId: item['user_login'],
            title: item['title'],
            cover: (item['thumbnail_url'] as String)
                .replaceAll('{width}', '640')
                .replaceAll('{height}', '360'),
            userName: item['user_name'],
            online: item['viewer_count'] ?? 0,
          ),
        );
      }
    }
    final next =
        (id == 'youtube'
                ? response['nextPageToken']
                : response['pagination']?['cursor'])
            as String?;
    if (next != null && next.isNotEmpty) _listingTokens[page + 1] = next;
    final result = LiveCategoryResult(
      hasMore: next != null && next.isNotEmpty,
      items: items,
    );
    _listingPages[page] = result;
    _listingAt ??= DateTime.now();
    return result;
  }

  Future<GlobalChatBatch> readYoutubeChat(
    LiveRoomDetail detail, {
    String? pageToken,
  }) async {
    _requireApi();
    final chatId = detail.data?['liveChatId'] as String?;
    if (id != 'youtube' || chatId == null || chatId.isEmpty) {
      throw const GlobalLiveException('该直播当前没有可读取的聊天，可能尚未开播、已关闭或已结束');
    }
    final response = await _get('liveChat/messages', {
      'liveChatId': chatId,
      'part': 'id,snippet,authorDetails',
      'maxResults': 200,
      if (pageToken != null) 'pageToken': pageToken,
    });
    return GlobalChatBatch.fromYoutube(response);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    final detail = await getRoomDetail(roomId: roomId);
    if (state(detail) == GlobalLiveState.unknown) {
      throw const GlobalLiveException('未配置官方 API，开播状态未知');
    }
    return detail.status;
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    if (page != 1) return LiveSearchRoomResult(hasMore: false, items: []);
    final target = GlobalLiveLink.parse(keyword, siteId: id);
    if (target == null) {
      throw const GlobalLiveException(
        '此入口支持精确链接、频道 ID / Handle 或 Twitch 频道名称，不支持关键词发现',
      );
    }
    final d = await getRoomDetail(roomId: target.roomId);
    return LiveSearchRoomResult(
      hasMore: false,
      items: [
        LiveRoomItem(
          roomId: d.roomId,
          title: d.title,
          cover: d.cover,
          userName: d.userName,
          online: d.online,
        ),
      ],
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    // Boolean-only anchor cards cannot truthfully show an unknown live state.
    throw const GlobalLiveException('请在直播搜索中输入频道链接或名称；未配置 API 时开播状态未知');
  }
}
