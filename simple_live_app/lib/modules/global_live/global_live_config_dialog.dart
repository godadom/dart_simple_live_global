import 'package:flutter/material.dart';
import 'package:simple_live_core/simple_live_core.dart';

Future<bool> showGlobalLiveConfig(
    BuildContext context, GlobalLiveSite site) async {
  final config = site.config;
  final first = TextEditingController(
      text:
          site.id == 'youtube' ? config.youtubeApiKey : config.twitchClientId);
  final token = TextEditingController(text: config.twitchAccessToken);
  final embed = TextEditingController(text: config.twitchEmbedPage);
  final chatUser = TextEditingController(text: config.twitchChatUser);
  final chatToken = TextEditingController(text: config.twitchChatToken);
  final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text('${site.name} 设置'),
            content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('凭据仅当前会话有效。直播列表、元数据及聊天需要官方接口权限；请勿输入 Client Secret。'),
              TextField(
                  controller: first,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                      labelText: site.id == 'youtube'
                          ? 'YouTube Data API Key'
                          : 'Twitch Client ID')),
              if (site.id == 'twitch') ...[
                TextField(
                    controller: token,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                        labelText: 'Twitch App Access Token（直播列表）')),
                TextField(
                    controller: embed,
                    decoration:
                        const InputDecoration(labelText: '自有 HTTPS 播放页面（可选）')),
                TextField(
                    controller: chatUser,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration:
                        const InputDecoration(labelText: '聊天令牌所属用户名（可选）')),
                TextField(
                    controller: chatToken,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                        labelText: 'User Access Token（仅需 chat:read）')),
                const Text('聊天令牌与 App Access Token 不同。仅接收消息，不提供发送、购买或账号操作。'),
              ] else
                const Text('聊天查询消耗 API 配额，按服务端间隔且至少每 30 秒读取一次。'),
            ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('应用'))
            ],
          ));
  if (saved == true) {
    if (site.id == 'youtube') {
      config.youtubeApiKey = first.text.trim();
    } else {
      config.twitchClientId = first.text.trim();
      config.twitchAccessToken = token.text.trim();
      config.twitchEmbedPage = embed.text.trim();
      config.twitchChatUser = chatUser.text.trim().toLowerCase();
      config.twitchChatToken = chatToken.text.trim();
    }
    site.clearCache();
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final field in [first, token, embed, chatUser, chatToken]) {
    field.dispose();
  }
  return saved == true;
}
