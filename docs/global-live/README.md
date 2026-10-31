# YouTube Live / Twitch

## 使用

主 App 首页或分类页选择 YouTube Live / Twitch，输入链接或频道标识；也可使用“链接解析”或直播搜索（精确输入，不是主播关键词搜索）。TV 在“热门直播”或分类平台列表中选择对应平台。

- YouTube：`youtube.com/watch?v=<11位ID>`、`youtu.be/<ID>`、`youtube.com/live/<ID>`、`youtube.com/channel/<UC…>`、`youtube.com/@Handle`；频道链接可带 `/live`。平台输入框还接受视频 ID、频道 ID、`@Handle`。
- Twitch：`twitch.tv/<channel>`、`www.twitch.tv/<channel>`、`m.twitch.tv/<channel>` 或频道名称，统一小写。拒绝目录、视频、设置等非频道路径。
- “本地关注”复用 Hive 的原有关注记录；在原有关注页管理分组、取消关注、导入导出及同步。没有官方关注接口。新记录使用 `youtube` / `twitch` siteId，旧记录结构不变。旧版客户端不认识新 siteId，建议两端都升级后同步。
- YouTube 视频 ID 只关注该场直播；持续关注频道应输入频道 ID / Handle，或在有 API 元数据时点“打开所属频道”。Handle 可被主播更改，稳定性优先时使用 UC 频道 ID。
- 点击官方播放器或成功打开外部浏览器时记录访问历史；历史不代表视频已实际播放成功。

## 播放支持

| 客户端 | YouTube | Twitch |
| --- | --- | --- |
| 主 App Android | 现有 flutter_inappwebview 加载官方 `/embed/<videoId>`，使用实际安装包名生成 HTTPS Referer；无法解析频道当前视频时打开官方频道页面 | 默认外部浏览器；可配置实际部署的 HTTPS 官方嵌入页面 |
| 主 App Windows / 其他系统 | 外部浏览器 | 外部浏览器 |
| TV App | 外部浏览器，设备须安装支持官方直播的浏览器 | 同左 |

不提取 HLS/DASH、不把网页地址交给 media_kit，不抓取 HTML，不绕过登录、年龄、地区、版权或嵌入限制。播放器原生错误提示保留；YouTube 101/150 通常表示禁止嵌入，153 表示客户端标识问题。遇到受限播放可点击“在浏览器中打开”。内嵌不提供账号页；离开应用后台会关闭内嵌播放器。没有聊天、付费、写操作、推荐流、录播下载、多开播放或原生播放器自动换台支持。

Twitch 内嵌必须部署本目录的 `twitch-player.html` 到自己控制的真实 HTTPS 站点，并把完整页面地址填入可选配置。页面从 `location.hostname` 设置 `parent`，App 只传频道名称，不传任何 API 凭据。不要用虚构域名、HTTP、本地文件或借用第三方域名。页面应直接作为顶层页面加载；若另行嵌套，需要按 Twitch 文档配置全部 parent 域名。宽高至少 400×300；较窄屏幕可能需要横屏。此仓库没有代用户部署或声明任何可用托管域名。

## 可选查询配置

页面右上角设置仅保存于当前进程内存，重启清空，不进入数据库、导出、日志或同步。基础链接解析、保存关注和官方播放入口无需 API 凭据。

- YouTube Data API Key：启用 YouTube Data API。通过 `channels.list`（ID / forHandle）、限定频道且 `eventType=live` 的 `search.list`、`videos.list` 获取状态、标题、封面、频道信息、可用观看人数。没有 Key 时不声称已获取这些元数据，显示原始标识及“状态未知”。频道头像由 channels 返回；直接视频详情可能没有频道头像。
- Twitch Client ID + App Access Token：用 Helix `users`、`streams` 查询昵称、头像、标题、封面、游戏和观看人数。令牌应由自己的可信服务按官方流程取得；客户端不接受 Client Secret，不实现账号 OAuth 登录或获取／自动刷新令牌。不要向他人分发包含私密令牌的安装包。
- 没有配置时刷新关注保持“未确认”，不会伪装离线。有配置时沿用关注刷新机制；失败也重置为未确认，详情页显示可读原因。
- 成功结果缓存：视频和 Twitch 2 分钟，YouTube 频道 15 分钟（频道解析耗用搜索额度）。401 提示凭据过期；403/429 提示配额、限流或拒绝访问并冷却 5 分钟；连接 10 秒、响应 15 秒超时；不无限重试。缓存意味着状态存在延迟。
- 频道无正在直播的视频显示未开播；指定视频可区分直播、预约、结束及普通视频。未知状态不能证明输入一定是直播，播放器可能显示已结束的原视频；配置 API 可在启动内嵌前识别并阻止普通视频／已结束直播。
- 当前只提供精确频道／链接查询；主播搜索页会提示改用直播搜索。没有全站关键词搜索或只读聊天。

截至实现时，YouTube 文档将 search.list 列为独立的每日查询配额（默认 100 次），其他常用读取端点使用独立单位配额；以项目控制台为准。多频道持续自动刷新仍可能用完额度。Twitch 配额按官方响应头与应用限制执行；当前实现采用保守冷却，尚未批量查询或自动管理令牌。生产分发前宜实现受控的元数据服务，避免让所有用户自行配置和暴露服务凭据。

## 官方依据和许可证

- [YouTube WebView 客户端标识及 Referer](https://developers.google.com/youtube/terms/required-minimum-functionality#embedded-player-api-client-identity)
- [YouTube IFrame Player API](https://developers.google.com/youtube/iframe_api_reference)
- [YouTube Data API 配额](https://developers.google.com/youtube/data/determine_quota_cost)
- [Twitch HTTPS / parent 要求](https://dev.twitch.tv/docs/embed/)
- [Twitch 官方视频播放器](https://dev.twitch.tv/docs/embed/video-and-clips/)
- [Twitch API 身份验证](https://dev.twitch.tv/docs/authentication/)

实现和简单字母图标为本次原创，未复制第三方项目代码或图标；复用项目已有依赖，无新增 pub 依赖。当前 UI 遵循仓库已有中文硬编码方式，仓库没有可复用的完整 ARB 本地化目录。

## 验证边界

核心 mock 测试覆盖链接安全、频道标识、直播／预约／结束／普通视频／离线／未知、API 失败与限流、缓存、凭据脱敏和原平台解析回归。无真实 YouTube/Twitch API 凭据或 Android/Windows 图形设备，本次不宣称真实直播播放通过。需要真机验收：正常直播、受限／禁止嵌入、浏览器不可用、频道离线、YouTube 频道切换下一场直播、电视遥控器交互、后台退出、网络切换。

DSH 检查：云端不存在 codex-delegate-to-dsh Skill、dsh_delegate MCP 或 dsh CLI；未委派任务，全部由 Codex 实施与检查。

### 本次执行结果

- 核心：96 个离线测试通过（含新增 33 个测试）。已使用 Clang 构建原有 QuickJS hook 后运行标准 `dart test`。
- 主 App：`flutter test --no-pub test/global_live_page_test.dart test/parse_controller_test.dart`，14 项通过。
- TV：`flutter test --no-pub test/global_live_page_test.dart`，4 项通过。
- 完整静态检查：主 App 和 TV 均为 No issues found；新增核心文件及解析器检查通过。
- `flutter build apk --debug --no-pub`：环境没有 Android SDK，未生成 APK。
- `flutter build windows --debug --no-pub`：当前 Linux 主机不支持 Windows 构建，未生成 Windows 安装包。
- 首次尝试全量核心测试发现 `douyin_game_artwork_test.dart` 的 4 个已有失败（期望旧 PNG 路径，实际为 WebP）；`simple_live_core_test.dart` 实际包含联网及长期聊天连接，已中止并将其排除在离线回归之外。未修改这两个现有测试。
- Flutter 3.41.9 工具与 Clang 在临时目录运行，未增加项目依赖或更新锁文件。无法用这些测试代替真实设备播放验证。
