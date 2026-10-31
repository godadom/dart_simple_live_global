/// Strict identifiers used for local favourites; never resolve arbitrary URLs.
class GlobalLiveLink {
  final String siteId;
  final String roomId;
  const GlobalLiveLink(this.siteId, this.roomId);
  static final _video = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _channel = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _handle = RegExp(r'^@[\p{L}\p{N}_.-]{3,30}$', unicode: true);
  static final _twitch = RegExp(r'^[a-zA-Z0-9_]{1,25}$');
  static const _reserved = {
    'directory',
    'downloads',
    'settings',
    'subscriptions',
    'inventory',
    'wallet',
    'search',
    'videos',
    'p',
    'turbo',
    'jobs',
    'login',
    'signup',
  };

  static GlobalLiveLink? parse(String value, {String? siteId}) {
    final text = value.trim();
    if (siteId == 'youtube') {
      if (_video.hasMatch(text)) return GlobalLiveLink(siteId!, text);
      if (_channel.hasMatch(text)) {
        return GlobalLiveLink(siteId!, 'channel/$text');
      }
      if (_handle.hasMatch(text)) return GlobalLiveLink(siteId!, text);
      if (text.startsWith('channel/') && _channel.hasMatch(text.substring(8))) {
        return GlobalLiveLink(siteId!, text);
      }
    }
    if (siteId == 'twitch' &&
        _twitch.hasMatch(text) &&
        !_reserved.contains(text.toLowerCase())) {
      return GlobalLiveLink(siteId!, text.toLowerCase());
    }
    try {
      final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort) {
        return null;
      }
      final host = uri.host.toLowerCase();
      final parts = uri.pathSegments.where((e) => e.isNotEmpty).toList();
      String? id;
      String? platform;
      if ({
        'youtube.com',
        'www.youtube.com',
        'm.youtube.com',
        'youtu.be',
        'www.youtu.be',
      }.contains(host)) {
        platform = 'youtube';
        if (host.endsWith('youtu.be') &&
            parts.length == 1 &&
            _video.hasMatch(parts[0])) {
          id = parts[0];
        }
        if (host.endsWith('youtube.com')) {
          if (parts.length == 1 &&
              parts[0] == 'watch' &&
              _video.hasMatch(uri.queryParameters['v'] ?? '')) {
            id = uri.queryParameters['v'];
          }
          if (parts.length == 2 &&
              {'live', 'embed'}.contains(parts[0]) &&
              _video.hasMatch(parts[1])) {
            id = parts[1];
          }
          if ((parts.length == 2 ||
                  (parts.length == 3 && parts[2] == 'live')) &&
              parts[0] == 'channel' &&
              _channel.hasMatch(parts[1])) {
            id = 'channel/${parts[1]}';
          }
          if ((parts.length == 1 ||
                  (parts.length == 2 && parts[1] == 'live')) &&
              _handle.hasMatch(parts[0])) {
            id = parts[0];
          }
        }
      } else if ({'twitch.tv', 'www.twitch.tv', 'm.twitch.tv'}.contains(host) &&
          parts.length == 1 &&
          _twitch.hasMatch(parts[0]) &&
          !_reserved.contains(parts[0].toLowerCase())) {
        platform = 'twitch';
        id = parts[0].toLowerCase();
      }
      return id == null || (siteId != null && siteId != platform)
          ? null
          : GlobalLiveLink(platform!, id);
    } on FormatException {
      return null;
    }
  }

  bool get isVideo => siteId == 'youtube' && _video.hasMatch(roomId);
  Uri get url => siteId == 'twitch'
      ? Uri.https('www.twitch.tv', '/$roomId')
      : isVideo
      ? Uri.https('www.youtube.com', '/watch', {'v': roomId})
      : Uri.https('www.youtube.com', '/$roomId/live');
}
