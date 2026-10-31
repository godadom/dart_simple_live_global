import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/follow_user_tag.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/modules/global_live/global_live_page.dart';

void main() {
  late Directory temp;
  late DBService db;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('global-live-test');
    Hive.init(temp.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    db = Get.put(DBService());
    await db.init();
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  for (final platform in ['youtube', 'twitch']) {
    testWidgets('$platform unknown state and local follow toggling',
        (tester) async {
      final room = platform == 'youtube' ? '@Example' : 'example';
      final site = Sites.allSites[platform]!;
      expect(site.liveSite, isA<GlobalLiveSite>());
      await tester.pumpWidget(
          GetMaterialApp(home: GlobalLivePage(site: site, roomId: room)));
      await tester.pumpAndSettle();
      expect(find.text('状态未知（未配置官方 API）'), findsOneWidget);
      await tester.ensureVisible(find.text('本地关注'));
      await tester.runAsync(() async {
        await tester.tap(find.text('本地关注'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final key = '${platform}_$room';
      expect(db.getFollowExist(key), isTrue);
      final exported = db.getFollowList().single.toJson();
      expect(FollowUser.fromJson(exported).siteId, platform);
      await tester.ensureVisible(find.text('取消本地关注'));
      await tester.runAsync(() async {
        await tester.tap(find.text('取消本地关注'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(db.getFollowExist(key), isFalse);
    });
  }
  test('both platforms survive storage reopen, groups and JSON round-trip',
      () async {
    for (final platform in ['youtube', 'twitch']) {
      final follow = FollowUser(
          id: '${platform}_example',
          roomId: 'example',
          siteId: platform,
          userName: 'Example',
          face: '',
          addTime: DateTime.now());
      await db.addFollow(follow);
      final tag = await db.addFollowTag(platform);
      tag!.userId.add(follow.id);
      await db.updateFollowTag(tag);
      expect(FollowUser.fromJson(follow.toJson()).toJson(), follow.toJson());
    }
    await Hive.close();
    await db.init();
    expect(db.getFollowList().map((e) => e.siteId),
        containsAll(['youtube', 'twitch']));
    expect(db.getFollowTagList().expand((e) => e.userId),
        containsAll(['youtube_example', 'twitch_example']));
  });
  testWidgets('invalid input is shown as an error without a follow button',
      (tester) async {
    await tester.pumpWidget(GetMaterialApp(
        home: GlobalLivePage(
            site: Sites.allSites['youtube']!,
            roomId: 'https://evil.example/watch?v=abcdefgh_-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入有效'), findsOneWidget);
    expect(find.text('本地关注'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
