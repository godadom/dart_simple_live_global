import 'dart:async';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'global_live_config_dialog.dart';
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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  LiveRoomDetail? _detail;
  GlobalLiveLink? _target;
  String? _error;
  bool _loading = false;
  Widget? _player;
  late final TabController _tabs;
  final _chatScroll = ScrollController();
  final _messages = <LiveMessage>[];
  final _superChats = <LiveSuperChatMessage>[];
  final _seen = <String>{};
  Timer? _chatTimer;
  TwitchReadOnlyChat? _twitchChat;
  String _chatStatus = '正在读取直播间信息';
  String? _chatPage;
  DateTime? _nextChatAt;
  int _chatGeneration = 0;
  bool _autoScroll = true;
  double _chatFontSize = 14;

  GlobalLiveSite get site => widget.site.liveSite as GlobalLiveSite;
  String get keyId => '${site.id}_${_target!.roomId}';
  String get _followRoomId {
    final channelId = _detail?.data?['channelId'] as String?;
    if (site.id == 'youtube' && channelId != null) {
      final channel = GlobalLiveLink.parse(channelId, siteId: 'youtube');
      if (channel != null) return channel.roomId;
    }
    return _target!.roomId;
  }

  String get _followKey => '${site.id}_$_followRoomId';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _input.text = widget.roomId ?? '';
    if (widget.roomId != null) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopChat();
    _tabs.dispose();
    _chatScroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        mounted) {
      _stopChat();
      setState(() => _player = null);
    } else if (state == AppLifecycleState.resumed) {
      _startChat();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _stopChat();
    _messages.clear();
    _superChats.clear();
    _seen.clear();
    _chatPage = null;
    setState(() {
      _chatStatus = '正在读取直播间信息';
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
      unawaited(_startChat());
      if (Platform.isAndroid && detail.status) unawaited(_play());
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
      if (db.getFollowExist(_followKey)) {
        await db.deleteFollow(_followKey);
      } else {
        await db.addFollow(
          FollowUser(
            id: _followKey,
            roomId: _followRoomId,
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
          height: double.infinity,
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
    if (await showGlobalLiveConfig(context, site) &&
        mounted &&
        _input.text.isNotEmpty) {
      await _load();
    }
  }

  void _stopChat() {
    _chatGeneration++;
    _chatTimer?.cancel();
    _chatTimer = null;
    unawaited(_twitchChat?.stop());
    _twitchChat = null;
  }

  void _acceptMessages(List<LiveMessage> messages) {
    for (final message in messages) {
      if (message.id != null && !_seen.add(message.id!)) continue;
      _messages.add(message);
      if (message.data is LiveSuperChatMessage) {
        _superChats.add(message.data as LiveSuperChatMessage);
      }
    }
    while (_messages.length > 300) {
      _messages.removeAt(0);
    }
    while (_superChats.length > 100) {
      _superChats.removeAt(0);
    }
    while (_seen.length > 1000) {
      _seen.remove(_seen.first);
    }
    if (mounted) setState(() {});
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _chatScroll.hasClients) {
          _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _deleteChat(String? id) {
    if (!mounted) return;
    setState(() {
      if (id == null) {
        _messages.clear();
        _superChats.clear();
      } else {
        _messages.removeWhere((m) => m.id == id);
        _superChats.removeWhere((m) => m.id == id);
      }
    });
  }

  Future<void> _startChat() async {
    _stopChat();
    final generation = _chatGeneration;
    if (_target == null || _detail == null) return;
    if (site.id == 'twitch') {
      setState(() => _chatStatus = '正在连接只读聊天');
      final config = site.config;
      final chat = TwitchReadOnlyChat();
      _twitchChat = chat;
      chat.onMessage = (message) {
        if (mounted && generation == _chatGeneration) {
          _acceptMessages([message]);
        }
      };
      chat.onDelete = (id) {
        if (generation == _chatGeneration) _deleteChat(id);
      };
      chat.onStatus = (status) {
        if (mounted && generation == _chatGeneration) {
          setState(() => _chatStatus = status);
        }
      };
      await chat.start(
          channel: _target!.roomId,
          user: config.twitchChatUser,
          token: config.twitchChatToken);
      return;
    }
    if (!site.configured || _detail!.data?['liveChatId'] == null) {
      setState(() => _chatStatus = site.configured
          ? '当前直播没有可读取的聊天，可能已关闭或尚未开播'
          : '配置 YouTube API Key 后可读取聊天和 Super Chat');
      return;
    }
    final wait = _nextChatAt?.difference(DateTime.now()) ?? Duration.zero;
    _chatTimer = Timer(
        wait.isNegative ? Duration.zero : wait, () => _pollYoutube(generation));
  }

  Future<void> _pollYoutube(int generation) async {
    if (!mounted || generation != _chatGeneration || _detail == null) return;
    try {
      final batch = await site.readYoutubeChat(_detail!, pageToken: _chatPage);
      if (!mounted || generation != _chatGeneration) return;
      _nextChatAt = DateTime.now().add(batch.pollAfter);
      _chatPage = batch.nextPageToken;
      if (batch.clear) _deleteChat(null);
      for (final id in batch.deletedIds) {
        _deleteChat(id);
      }
      setState(() => _chatStatus = batch.ended ? '直播聊天已结束' : '已连接只读聊天');
      _acceptMessages(batch.messages);
      if (!batch.ended) {
        _chatTimer = Timer(batch.pollAfter, () => _pollYoutube(generation));
      }
    } catch (e) {
      if (mounted && generation == _chatGeneration) {
        _nextChatAt = DateTime.now().add(const Duration(seconds: 30));
        setState(() =>
            _chatStatus = e is GlobalLiveException ? e.message : '聊天读取失败，请重试');
      }
    }
  }

  Future<void> _tags() async {
    if (_target == null) return;
    final db = DBService.instance;
    final roomKey = _followKey;
    if (!db.getFollowExist(roomKey)) await _follow();
    final follow = db.followBox.get(roomKey);
    if (follow == null || !mounted) return;
    final tags = db.getFollowTagList();
    final selection = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('设置标签'),
              children: [
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, '全部'),
                    child: const Text('全部')),
                ...tags.map((tag) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, tag.tag),
                    child: Text(tag.tag))),
                if (tags.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16), child: Text('可在关注页创建和管理分组')),
              ],
            ));
    if (selection == null) return;
    for (final tag in tags) {
      tag.userId.remove(follow.id);
      if (tag.tag == selection) tag.userId.add(follow.id);
      await db.updateFollowTag(tag);
    }
    follow.tag = selection;
    await db.addFollow(follow);
    EventBus.instance.emit(Constant.kUpdateFollow, follow.id);
    if (mounted) setState(() {});
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

  Widget _playArea() => ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
          child: _player ??
              Stack(fit: StackFit.expand, children: [
                if ((_detail?.cover ?? '').isNotEmpty)
                  Image.network(_detail!.cover,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                Center(
                    child: FilledButton.icon(
                        onPressed: _loading || _target == null ? null : _play,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('官方播放器'))),
              ])));

  Widget _roomInfo() => Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        CircleAvatar(
            radius: 26,
            child: ClipOval(
                child: (_detail?.userAvatar ?? '').isEmpty
                    ? const Icon(Icons.person)
                    : Image.network(_detail!.userAvatar,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.person)))),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_detail?.userName ?? _target?.roomId ?? widget.site.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(
              [
                widget.site.name,
                if (_detail?.categoryName != null) _detail!.categoryName!
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall),
        ])),
        Flexible(
            child: Text(
                (_detail?.online ?? 0) > 0
                    ? '🔥 在线 ${_detail!.online}'
                    : statusText,
                style: Theme.of(context).textTheme.bodySmall)),
      ]));

  Widget _chatPanel() => Column(children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              Expanded(
                  child: Text(_chatStatus,
                      style: Theme.of(context).textTheme.bodySmall)),
              IconButton(
                  tooltip: '重新连接聊天',
                  onPressed: _startChat,
                  icon: const Icon(Icons.sync, size: 18)),
            ])),
        Expanded(
            child: ListView.builder(
                controller: _chatScroll,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final item = _messages[index];
                  return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: '${item.userName}：',
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.primary)),
                            TextSpan(text: item.message),
                            if (item.data is LiveSuperChatMessage)
                              TextSpan(
                                  text:
                                      '  ${(item.data as LiveSuperChatMessage).priceDisplay ?? ""}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                          ]),
                          style: TextStyle(fontSize: _chatFontSize)));
                })),
      ]);
  Widget _scPanel() => _superChats.isEmpty
      ? Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                  site.id == 'youtube'
                      ? '本次连接尚未收到 Super Chat / Super Sticker，消息将显示在这里'
                      : '本次连接尚未收到 Cheers；Bits 消息将显示在这里（Twitch 没有 YouTube Super Chat）',
                  textAlign: TextAlign.center)))
      : ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: _superChats.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => SuperChatCard(
              _superChats[_superChats.length - 1 - i],
              onExpire: null,
              showCountdown: false));

  Widget _followPanel() {
    final followed =
        _target != null && DBService.instance.getFollowExist(_followKey);
    final tag =
        followed ? DBService.instance.followBox.get(_followKey)?.tag : null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(followed
          ? '已保存到本地关注${tag == null ? "" : " · $tag"}'
          : '关注频道，方便下次从关注列表打开'),
      if (_target != null)
        TextButton(
            onPressed: _follow, child: Text(followed ? '取消本地关注' : '本地关注')),
      TextButton.icon(
          onPressed: _tags,
          icon: const Icon(Icons.sell_outlined),
          label: const Text('设置标签')),
      if (site.id == 'youtube')
        const Text('已识别所属频道时会保存频道关注；没有 API 时，视频链接只能保存这一场直播。'),
      if (site.id == 'youtube' &&
          _target?.isVideo == true &&
          _detail?.data?['channelId'] != null)
        TextButton(
            onPressed: () {
              _input.text = 'channel/${_detail!.data['channelId']}';
              _load();
            },
            child: const Text('打开所属频道（用于持续关注）')),
    ]);
  }

  Widget _settingsPanel() => ListView(children: [
        ListTile(
            title: const Text('平台与 API 设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _configure),
        SwitchListTile(
            title: const Text('聊天自动滚动'),
            value: _autoScroll,
            onChanged: (v) => setState(() => _autoScroll = v)),
        ListTile(
            title: const Text('聊天字号'),
            subtitle: Slider(
                value: _chatFontSize,
                min: 12,
                max: 24,
                divisions: 6,
                onChanged: (v) => setState(() => _chatFontSize = v))),
        ListTile(
            title: const Text('清空本次聊天和 SC'), onTap: () => _deleteChat(null)),
        ListTile(
            title: const Text('在浏览器中打开'),
            onTap: _target == null ? null : _browser),
        if (_player != null)
          ListTile(
              title: const Text('关闭播放器'),
              onTap: () => setState(() => _player = null)),
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('清晰度、字幕、音量及全屏由官方播放器控制。聊天只读；登录、地区和嵌入限制以平台提示为准。')),
      ]);
  Widget _panels() => Column(children: [
        TabBar(controller: _tabs, tabs: [
          const Tab(text: '聊天'),
          Tab(
              text:
                  '${site.id == "youtube" ? "SC" : "Cheers"}(${_superChats.length})'),
          const Tab(text: '关注'),
          const Tab(text: '设置')
        ]),
        Expanded(
            child: TabBarView(controller: _tabs, children: [
          _chatPanel(),
          _scPanel(),
          _followPanel(),
          _settingsPanel()
        ])),
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(_detail?.title ?? widget.site.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            centerTitle: true,
            actions: [
              IconButton(
                  tooltip: '平台设置',
                  onPressed: _configure,
                  icon: const Icon(Icons.more_horiz))
            ]),
        bottomNavigationBar: _target == null
            ? null
            : SafeArea(
                top: false,
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      TextButton.icon(
                          onPressed: _follow,
                          icon: Icon(
                              DBService.instance.getFollowExist(_followKey)
                                  ? Icons.favorite
                                  : Icons.favorite_border),
                          label: const Text('关注')),
                      TextButton.icon(
                          onPressed: _tags,
                          icon: const Icon(Icons.sell_outlined),
                          label: const Text('标签')),
                      TextButton.icon(
                          onPressed: _loading
                              ? null
                              : () {
                                  site.clearCache();
                                  _load();
                                },
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新')),
                      TextButton.icon(
                          onPressed: () => SharePlus.instance
                              .share(ShareParams(uri: _target!.url)),
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('分享')),
                    ])),
        body: Column(children: [
          if (widget.roomId == null)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Expanded(
                      child: TextField(
                          controller: _input,
                          decoration:
                              const InputDecoration(hintText: '直播链接或频道名称'),
                          onSubmitted: (_) => _load())),
                  IconButton(
                      onPressed: _load, icon: const Icon(Icons.arrow_forward)),
                ])),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth > 750 ||
                (constraints.maxWidth > 500 &&
                    constraints.maxWidth > constraints.maxHeight * 1.5)) {
              return Row(children: [
                Expanded(
                    child: Column(
                        children: [Expanded(child: _playArea()), _roomInfo()])),
                SizedBox(width: 340, child: _panels())
              ]);
            }
            final playerHeight = (constraints.maxWidth * 9 / 16)
                .clamp(0.0, constraints.maxHeight * 0.48);
            return Column(children: [
              SizedBox(height: playerHeight, child: _playArea()),
              _roomInfo(),
              Expanded(child: _panels())
            ]);
          })),
        ]),
      );
}
