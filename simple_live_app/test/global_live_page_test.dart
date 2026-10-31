import 'package:simple_live_app/modules/global_live/global_live_home_view.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/modules/global_live/global_live_page.dart';

class FixtureGlobalSite extends GlobalLiveSite {
  FixtureGlobalSite() : super('youtube') {
    config.youtubeApiKey = 'fixture-only';
  }
  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async =>
      LiveCategoryResult(
          hasMore: false,
          items: page > 1
              ? []
              : [
                  LiveRoomItem(
                      roomId: 'abcdefgh_-1',
                      title: 'Live fixture one',
                      cover: '',
                      userName: 'Host one'),
                  LiveRoomItem(
                      roomId: 'abcdefgh_-2',
                      title: 'Live fixture two',
                      cover: '',
                      userName: 'Host two'),
                ]);
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async =>
      LiveRoomDetail(
          roomId: roomId,
          title: 'Fixture live room',
          cover: '',
          userName: 'Fixture host',
          userAvatar: '',
          online: 42,
          status: true,
          url: 'https://www.youtube.com/watch?v=$roomId',
          data: {
            'state': GlobalLiveState.live,
            'videoId': roomId,
            'liveChatId': 'fixture-chat'
          });
  @override
  Future<GlobalChatBatch> readYoutubeChat(LiveRoomDetail detail,
          {String? pageToken}) async =>
      GlobalChatBatch(messages: [
        LiveMessage(
            id: 'text',
            type: LiveMessageType.chat,
            userName: 'Viewer',
            message: 'Hello live chat',
            color: LiveMessageColor.white),
        LiveMessage(
            id: 'sc',
            type: LiveMessageType.superChat,
            userName: 'SC viewer',
            message: 'Thanks for the stream',
            color: LiveMessageColor.white,
            data: LiveSuperChatMessage(
                id: 'sc',
                userName: 'SC viewer',
                face: '',
                message: 'Thanks for the stream',
                price: 0,
                priceDisplay: r'US$5.00',
                startTime: DateTime(2026),
                endTime: DateTime(2026),
                backgroundColor: '#ffeb99',
                backgroundBottomColor: '#8a5b00')),
      ]);
}

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
      expect(find.widgetWithText(Tab, '聊天'), findsOneWidget);
      expect(find.widgetWithText(Tab, '设置'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, '关注'));
      await tester.pumpAndSettle();
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
  testWidgets('global home reuses native cards and opens the matching room',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final site = Site(
        id: 'youtube',
        name: 'YouTube Live',
        logo: 'assets/images/youtube.png',
        liveSite: FixtureGlobalSite());
    await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: GlobalLiveHomeView(site: site))));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(LiveRoomCard), findsNWidgets(2));
    expect(find.text('Live fixture one'), findsOneWidget);
    await tester.tap(find.text('Live fixture one'));
    await tester.pumpAndSettle();
    expect(find.byType(GlobalLivePage), findsOneWidget);
    expect(find.text('Fixture live room'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('room shows real-currency SC, tags and portrait/landscape panels',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => db.addFollowTag('Group'));
    final site = Site(
        id: 'youtube',
        name: 'YouTube Live',
        logo: 'assets/images/youtube.png',
        liveSite: FixtureGlobalSite());
    await tester.pumpWidget(GetMaterialApp(
        home: GlobalLivePage(site: site, roomId: 'abcdefgh_-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hello live chat'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'SC(1)'));
    await tester.pumpAndSettle();
    expect(find.byType(SuperChatCard), findsOneWidget);
    expect(find.text(r'US$5.00'), findsOneWidget);
    expect(find.text('￥0'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('标签'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Group'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(db.followBox.get('youtube_abcdefgh_-1')!.tag, 'Group');
    expect(db.getFollowTagList().single.userId, ['youtube_abcdefgh_-1']);
    tester.view.physicalSize = const Size(700, 350);
    await tester.pumpAndSettle();
    expect(find.byType(SuperChatCard), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
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
