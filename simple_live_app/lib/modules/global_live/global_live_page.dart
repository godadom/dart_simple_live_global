import 'dart:io';

import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';

class GlobalLivePage extends StatefulWidget {
  final Site site;
  final String? roomId;
  const GlobalLivePage({super.key, required this.site, this.roomId});
  @override
  State<GlobalLivePage> createState() => _GlobalLivePageState();
}

class _GlobalLivePageState extends State<GlobalLivePage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  LiveRoomDetail? _detail;
  GlobalLiveLink? _target;
  String? _error;
  bool _loading = false;
  Widget? _player;
  GlobalLiveSite get site => widget.site.liveSite as GlobalLiveSite;
  String get keyId => '${site.id}_${_target!.roomId}';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input.text = widget.roomId ?? '';
    if (widget.roomId != null) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        mounted) {
      setState(() => _player = null);
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _detail = null;
      _target = null;
      _player = null;
      _loading = true;
    });
    try {
      final target = site.link(_input.text);
      _target = target;
      final detail = await site.getRoomDetail(roomId: target.roomId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is GlobalLiveException ? e.message : '查询失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _history() async {
    await DBService.instance.addOrUpdateHistory(
      History(
        id: keyId,
        roomId: _target!.roomId,
        siteId: site.id,
        userName: _detail?.userName ?? _target!.roomId,
        face: _detail?.userAvatar ?? '',
        updateTime: DateTime.now(),
      ),
    );
  }

  Future<void> _browser() async {
    try {
      final opened = await launchUrl(
        _target!.url,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('browser');
      await _history();
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开浏览器，请检查系统是否安装浏览器');
    }
  }

  Future<void> _follow() async {
    try {
      final db = DBService.instance;
      if (db.getFollowExist(keyId)) {
        await db.deleteFollow(keyId);
      } else {
        await db.addFollow(
          FollowUser(
            id: keyId,
            roomId: _target!.roomId,
            siteId: site.id,
            userName: _detail?.userName ?? _target!.roomId,
            face: _detail?.userAvatar ?? '',
            addTime: DateTime.now(),
            roomTitle: _detail?.title ?? '',
            roomCover: _detail?.cover ?? '',
          ),
        );
      }
      EventBus.instance.emit(Constant.kUpdateFollow, null);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '本地关注保存失败，请重试');
    }
  }

  Future<void> _play() async {
    if (!Platform.isAndroid) {
      await _browser();
      return;
    }
    final openedRoom = keyId;
    final state = _detail == null
        ? GlobalLiveState.unknown
        : GlobalLiveSite.state(_detail!);
    if ({
      GlobalLiveState.ended,
      GlobalLiveState.video,
      GlobalLiveState.offline,
    }.contains(state)) {
      setState(() => _error = '当前没有可播放的直播，可在官方页面查看状态');
      return;
    }
    try {
      URLRequest request;
      if (site.id == 'youtube') {
        final video = _detail?.data?['videoId'] as String? ??
            (_target!.isVideo ? _target!.roomId : null);
        if (video == null) {
          await _browser();
          return;
        }
        final package = await PackageInfo.fromPlatform();
        request = URLRequest(
          url: WebUri('https://www.youtube.com/embed/$video?playsinline=1'),
          headers: {'Referer': 'https://${package.packageName.toLowerCase()}/'},
        );
      } else {
        final page = Uri.tryParse(site.config.twitchEmbedPage);
        if (page == null ||
            page.scheme != 'https' ||
            page.host.isEmpty ||
            page.userInfo.isNotEmpty) {
          await _browser();
          return;
        }
        request = URLRequest(
          url: WebUri(
            page.replace(
                queryParameters: {'channel': _target!.roomId}).toString(),
          ),
        );
      }
      if (!mounted || _target == null || keyId != openedRoom) return;
      setState(
        () => _player = SizedBox(
          height: 320,
          child: InAppWebView(
            key: UniqueKey(),
            initialUrlRequest: request,
            initialSettings: InAppWebViewSettings(
              mediaPlaybackRequiresUserGesture: true,
              allowsInlineMediaPlayback: true,
              useShouldOverrideUrlLoading: true,
            ),
            shouldOverrideUrlLoading: (controller, action) async {
              if (!action.isForMainFrame) return NavigationActionPolicy.ALLOW;
              final destination = action.request.url;
              if (destination == request.url ||
                  destination?.toString() == 'about:blank') {
                return NavigationActionPolicy.ALLOW;
              }
              // Official account/interaction pages are not an in-app feature.
              return NavigationActionPolicy.CANCEL;
            },
            onReceivedError: (controller, request, error) {
              if (mounted && request.isForMainFrame == true) {
                setState(() => _error = '播放器网络加载失败，可重试或在浏览器中打开');
              }
            },
          ),
        ),
      );
      await _history();
    } catch (_) {
      if (mounted) setState(() => _error = '无法启动官方播放器，请在浏览器中打开');
    }
  }

  Future<void> _configure() async {
    final config = site.config;
    final first = TextEditingController(
      text: site.id == 'youtube' ? config.youtubeApiKey : config.twitchClientId,
    );
    final token = TextEditingController(text: config.twitchAccessToken);
    final embed = TextEditingController(text: config.twitchEmbedPage);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('可选官方 API 配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '仅当前会话有效，不写入备份或同步。无需配置也可保存频道及在官方页面观看。请勿输入 Client Secret。',
              ),
              TextField(
                controller: first,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: site.id == 'youtube'
                      ? 'YouTube Data API Key'
                      : 'Twitch Client ID',
                ),
              ),
              if (site.id == 'twitch') ...[
                TextField(
                  controller: token,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Twitch App Access Token',
                  ),
                ),
                TextField(
                  controller: embed,
                  decoration: const InputDecoration(
                    labelText: '自有 HTTPS 播放页面（可选）',
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (saved == true) {
      if (site.id == 'youtube') {
        config.youtubeApiKey = first.text.trim();
      } else {
        config.twitchClientId = first.text.trim();
        config.twitchAccessToken = token.text.trim();
        config.twitchEmbedPage = embed.text.trim();
      }
      site.clearCache();
      if (_input.text.isNotEmpty && mounted) await _load();
    }
    // Dialog route animations can retain text fields until the next frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    first.dispose();
    token.dispose();
    embed.dispose();
  }

  String get statusText {
    if (_detail == null) return '状态未知';
    return switch (GlobalLiveSite.state(_detail!)) {
      GlobalLiveState.unknown => '状态未知（未配置官方 API）',
      GlobalLiveState.live => '正在直播',
      GlobalLiveState.offline => '频道当前未开播',
      GlobalLiveState.upcoming => '直播尚未开始',
      GlobalLiveState.ended => '直播已结束',
      GlobalLiveState.video => '普通视频，不是正在进行的直播',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.site.name),
          actions: [
            IconButton(
              onPressed: _loading ? null : _configure,
              icon: const Icon(Icons.settings),
              tooltip: '可选官方 API 配置',
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _input,
              onSubmitted: (_) {
                if (!_loading) _load();
              },
              decoration: const InputDecoration(
                labelText: '直播链接 / YouTube 频道 ID、@Handle / Twitch 频道名称',
              ),
            ),
            FilledButton(
              onPressed: _loading ? null : _load,
              child: const Text('打开频道'),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_target != null && !_loading) ...[
              Text(
                _detail?.title ?? _target!.roomId,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(_detail?.userName ?? ''),
              Text(statusText),
              if (_detail?.categoryName != null) Text(_detail!.categoryName!),
              if ((_detail?.online ?? 0) > 0) Text('观看人数：${_detail!.online}'),
              if ((_detail?.cover ?? '').isNotEmpty)
                Image.network(
                  _detail!.cover,
                  height: 160,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: _play, child: const Text('官方播放器')),
                  TextButton(onPressed: _browser, child: const Text('在浏览器中打开')),
                  TextButton(
                    onPressed: _follow,
                    child: Text(
                      DBService.instance.getFollowExist(keyId)
                          ? '取消本地关注'
                          : '本地关注',
                    ),
                  ),
                  if (site.id == 'youtube' &&
                      _target!.isVideo &&
                      _detail?.data?['channelId'] != null)
                    TextButton(
                      onPressed: () {
                        _input.text = 'channel/${_detail!.data['channelId']}';
                        _load();
                      },
                      child: const Text('打开所属频道（用于持续关注）'),
                    ),
                ],
              ),
              const Text(
                'YouTube 视频链接仅代表该场直播；持续关注请保存频道。登录、地区、年龄或嵌入限制以官方播放器提示为准，可改用浏览器。',
              ),
              Text(
                Platform.isAndroid
                    ? 'Twitch 内嵌需要自有 HTTPS 播放页面；未配置时使用浏览器。聊天暂不接入。'
                    : '当前系统使用外部浏览器播放；本地关注、历史及 API 查询仍可使用。',
              ),
              if (_player != null) ...[
                TextButton(
                  onPressed: () => setState(() => _player = null),
                  child: const Text('关闭播放器'),
                ),
                _player!,
              ],
            ],
          ],
        ),
      );
}
