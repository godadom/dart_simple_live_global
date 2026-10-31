import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/modules/home/home_list_view.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'global_live_config_dialog.dart';

/// Same cards, refresh and pagination as the other platforms.
class GlobalLiveHomeView extends StatelessWidget {
  final Site site;
  const GlobalLiveHomeView({super.key, required this.site});
  Future<void> _open(BuildContext context) async {
    final input = TextEditingController();
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('打开直播频道'),
              content: TextField(
                  controller: input,
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: '直播链接 / 频道 ID / @Handle / Twitch 名称'),
                  onSubmitted: (value) => Navigator.pop(context, value)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, input.text),
                    child: const Text('打开'))
              ],
            ));
    if (value != null) {
      final link = GlobalLiveLink.parse(value, siteId: site.id);
      if (link != null) {
        AppNavigator.toLiveRoomDetail(site: site, roomId: link.roomId);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法识别此频道链接')));
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<HomeListController>(tag: site.id)) {
      Get.put(HomeListController(site), tag: site.id);
    }
    return Column(children: [
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            const Expanded(
                child: Text('正在直播',
                    style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(
                onPressed: () => _open(context),
                icon: const Icon(Icons.link),
                label: const Text('打开频道')),
            IconButton(
                tooltip: '平台设置',
                icon: const Icon(Icons.tune),
                onPressed: () async {
                  if (await showGlobalLiveConfig(
                      context, site.liveSite as GlobalLiveSite)) {
                    await Get.find<HomeListController>(tag: site.id)
                        .refreshData();
                  }
                }),
          ])),
      Expanded(child: HomeListView(site.id)),
    ]);
  }
}
