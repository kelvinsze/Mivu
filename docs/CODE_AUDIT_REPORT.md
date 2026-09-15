# Mivu 全面代码审计报告 (Comprehensive Code Audit Report)

**审计日期**：2026-09-15  
**复核日期**：2026-09-15  
**审计目标**：Mivu 跨平台媒体播放器工程（iOS 客户端 + `ratings-api` Cloudflare Workers 服务）  
**审计范围**：
- **iOS 核心框架**：`Sources/MediaCore` (PlaybackCore 双引擎、Session、History、Ratings 客户端)
- **投送与局域网服务**：`Sources/Receiver` (SSDP 组播/单播发现、HTTP 轻量服务、SOAP/UPnP 控制)
- **个人媒体库适配器**：`Sources/Sources/PersonalMedia` (Emby、Jellyfin、WebDAV、SMB)
- **车载系统集成**：`Sources/CarPlay` (CPTemplate 架构、车载视频播放检测、SceneDelegate)
- **UI 与交互层**：`Sources/iPhone` (HomeView, PlayerView 渲染图层与手势系统)
- **云端评分与安全鉴权**：`ratings-api/` (App Attest 硬件认证与断言、D1 数据库、多源评分聚合与熔断)
- **工程配置与证书规范**：`project.yml`、`Mivu.entitlements`、`Info.plist`、构建脚本

---

## 1. 执行摘要与架构全景 (Executive Summary & Architecture)

Mivu 是一款面向 Apple 生态的高性能、隐私优先的个人流媒体客户端。系统不仅支持 Emby、Jellyfin、WebDAV 与 SMB 等个人私有媒体源，还内置了 DLNA/UPnP 接收端支持移动投送，并通过 CarPlay 扩展提供了车载视听能力。

```
                    ┌────────────────────────┐
                    │    UI / DLNA / CarPlay │
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │     PlayerService      │
                    │ (Session/NowPlaying/   │
                    │  History/RemoteCommand)│
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │   PlayerEngine Seam    │
                    └─────┬────────────┬─────┘
                          │            │
             .native route│            │.mpv route
                          ▼            ▼
                 ┌──────────────┐ ┌──────────────┐
                 │AVPlayerEngine│ │MPVPlayerEngine│
                 │(AVFoundation)│ │(libmpv+CGL/  │
                 │              │ │ AVSampleBuf) │
                 └──────────────┘ └──────────────┘
```

### 架构评估要点
1. **模块隔离度高（Seam Architecture）**：`PlayerEngine` 协议成功屏蔽了底层 AVFoundation 与 libmpv 的 C 结构体细节，UI 与系统集成层不直接耦合解码器。
2. **渐进式流媒体候选降级**：`MediaPlaybackInfoSelector` 实现了 `DirectPlay → DirectStream → Transcode` 梯级有序候选，兼顾原生与转码需求。
3. **设备端硬件安全**：评分接口依托 Apple DeviceCheck App Attest 实现零共享密钥访问，私钥严格受保护于 Secure Enclave。
4. **即时问题发现**：当前存在 3 处 P0 级缺陷（1 处单测失败、1 处 App Store 审核拒审隐患、1 处设备恢复后永久瘫痪），以及多处并发竞争、资源泄漏、安全验证缺口和投屏兼容性问题。

---

## 2. 缺陷与单测失败项 (Critical Issues & Test Failures)

### 🔴 P0-1: `SOAPParser` DIDL-Lite 视频标题解析失败（导致单元测试未通过）
- **涉及文件**：[`Sources/Receiver/SOAPParser.swift#L47-L58`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift#L47-L58)、[`Tests/SOAPParserTests.swift#L16-L27`](file:///Users/kelvinsze/Projects/Mivu/Tests/SOAPParserTests.swift#L16-L27)
- **问题分析**：
  运行 `MivuTests/SOAPParserTests` 时报错：
  ```text
  SOAPParserTests.testExtractTitleFromDIDLLite: XCTAssertEqual failed: ("nil") is not equal to ("Optional("Sample Video Title")")
  ```
  在标准 UPnP `SetAVTransportURI` 协议中，`CurrentURIMetaData` 是作为 XML 转义实体嵌入在 SOAP XML 内的（如 `&lt;DIDL-Lite...&gt;&lt;dc:title&gt;...&lt;/dc:title&gt;`）。当前实现直接对传入的原始字符串执行未转义的正则表达式 `<dc:title[^>]*>(.*?)</dc:title>`。当字符串包含 `&lt;` 实体时，正则直接失败返回 `nil`，导致投送端无法提取正确的视频标题。
- **修复方案**：
  在执行正则表达式之前先进行 `unescapeXML` 处理：
  ```swift
  public static func extractTitleFromDIDLLite(_ didlString: String) -> String? {
      guard !didlString.isEmpty else { return nil }
      let unescaped = unescapeXML(didlString)
      let pattern = "<dc:title[^>]*>(.*?)</dc:title>"
      if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
         let match = regex.firstMatch(in: unescaped, options: [], range: NSRange(location: 0, length: unescaped.utf16.count)),
         let titleRange = Range(match.range(at: 1), in: unescaped) {
          let rawTitle = String(unescaped[titleRange])
          return unescapeXML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return nil
  }
  ```

---

### 🔴 P0-2: `PhoneSceneDelegate` 挂载车载场景违规（App Store 审核高危）
- **涉及文件**：[`Sources/Application/PhoneSceneDelegate.swift#L12-L20`](file:///Users/kelvinsze/Projects/Mivu/Sources/Application/PhoneSceneDelegate.swift#L12-L20)、[`Sources/Application/MivuApp.swift#L55-L60`](file:///Users/kelvinsze/Projects/Mivu/Sources/Application/MivuApp.swift#L55-L60)、[`Sources/Info.plist#L79-L89`](file:///Users/kelvinsze/Projects/Mivu/Sources/Info.plist#L79-L89)
- **问题分析**：
  在 `PhoneSceneDelegate` 中：
  ```swift
  if session.role.rawValue == "UIWindowSceneSessionRoleCarPlay",
     let windowScene = scene as? UIWindowScene {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = UIHostingController(rootView: MainTabView()) // ⚠️
      carPlayWindow = window
      window.makeKeyAndVisible()
  }
  ```
  1. Apple CarPlay 人机交互指南（HIG）与审核条例（Guideline 2.5.1 / 3.2.3）明确规定：**车载音频/视频应用必须使用 `CarPlay.framework` 提供的规范模板（如 `CPTemplateApplicationScene`、`CPListTemplate` 等）**。
  2. 将手机端专用的 `MainTabView` 强行挂载至 CarPlay 窗口，在车机屏幕上不仅会出现触控区域不匹配、排版拉伸异常，且在提审时会触发人工审核驳回。
  3. **（复核补充）** 违规路由存在于三处联动代码中，修复时必须全部清理：
     - `PhoneSceneDelegate.swift`：删除 `carPlayWindow` 属性和 `UIWindowSceneSessionRoleCarPlay` 分支。
     - `MivuApp.swift`（`AppDelegate`）：删除 `else if sceneRole.rawValue == "UIWindowSceneSessionRoleCarPlay"` 分支，该分支将 CarPlay 窗口场景路由给 `PhoneSceneDelegate`。
     - `Info.plist`：删除 `UIWindowSceneSessionRoleCarPlay` 整个键及其子字典。
  4. **（复核补充）** 该违规挂载还会导致**重复的 SwiftUI 状态层级**：CarPlay 窗口和手机主窗口各实例化一份独立的 `MainTabView`，造成双重网络轮询、观察者和内存泄漏。
- **修复方案**：
  - 彻底废除上述三处对 `UIWindowSceneSessionRoleCarPlay` 的引用。
  - 所有 CarPlay 场景连接统一收归于 [`CarPlaySceneDelegate`](file:///Users/kelvinsze/Projects/Mivu/Sources/CarPlay/CarPlaySceneDelegate.swift) 和 `CPTemplateApplicationSceneSessionRoleApplication`。
  - `PhoneSceneDelegate` 仅保留深度链接处理（`handleIncomingURL`）职责。

---

### 🔴 P0-3: `AppAttestClient` 设备恢复后永久失效（Permanent Deadlock）
- **涉及文件**：[`Sources/MediaCore/AppAttestClient.swift#L33-L35`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/AppAttestClient.swift#L33-L35)
- **问题分析**：
  `ensureKeyID` 首先检查 `UserDefaults` 中是否已存储 `keyIDKey`：
  ```swift
  if let existing = UserDefaults.standard.string(forKey: keyIDKey) { return existing }
  ```
  当用户从 iCloud 或 iTunes 备份恢复 iPhone/iPad 时，`UserDefaults` 被恢复，但 **Apple Secure Enclave 中的私钥不可迁移且不包含在备份内**。后续所有 `generateAssertion(keyID: existing, ...)` 调用都会在 Secure Enclave 层面失败，而 `sessionToken` 的 `catch { return nil }` 会吞掉错误且**永远不会清除已缓存的 `keyIDKey`**。客户端将永久使用一个 Secure Enclave 已不可达的 Key ID 反复尝试并失败。
- **影响**：评分功能**永久瘫痪**，无法自愈，用户必须手动清除应用数据或重新安装。
- **修复方案**：
  1. 在 `generateAssertion` 或 `attestKey` 调用失败时捕获 `DCError`，检测是否为 key 不可用错误，若是则清除 `keyIDKey`、`tokenKey`、`tokenExpiryKey`，触发重新注册流程。
  2. 暴露 `public func resetAllAttestation()` 方法作为最终手段。

---

## 3. 并发、性能与资源生命周期 (Concurrency & Resource Management)

### 🟡 P1-1: App Attest 令牌失效无法主动刷新与重试
- **涉及文件**：[`Sources/MediaCore/AppAttestClient.swift#L14-L30`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/AppAttestClient.swift#L14-L30)、[`Sources/MediaCore/UnifiedRatingsAPIClient.swift#L21-L32`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/UnifiedRatingsAPIClient.swift#L21-L32)
- **问题分析**：
  1. `AppAttestClient` 计算并持久化 Token 的本地有效期（`tokenExpiryKey`）。如果云端 Worker 发生秘钥轮换（`APP_ATTEST_JWT_SECRET` 重新配置）或 Token 被提前吊销，服务端将直接返回 `401 Unauthorized`。
  2. `UnifiedRatingsAPIClient` 遇到非 200 响应时直接静默 `return nil`，**没有回调通知 `AppAttestClient` 清除本地 Token 缓存**。
  3. 客户端在之后的 15 分钟内会持续重用此失效 Token，导致评分接口处于全面瘫痪状态，直到本地时间自然越过过期阈值。
  4. **（复核补充）** `UnifiedRatingsAPIClient` 中所有错误（网络故障、401/403/429/500、JSON 解码失败）均被 `try?` + `guard` 统一吞没为 `return nil`，完全没有诊断日志或遥测上报。
- **修复方案**：
  - 在 `AppAttestClient` 暴露 `invalidateSessionToken()` 方法。
  - 在 `UnifiedRatingsAPIClient` 检测到 401 状态码时，调用 `invalidateSessionToken()` 并自动尝试重新生成断言（Assertion）换取新令牌进行一次轻量重试。
  - 为非 200 响应添加结构化日志。

### 🟡 P1-2: `AppAttestClient` Actor 重入导致 Thundering Herd 并发竞争
- **涉及文件**：[`Sources/MediaCore/AppAttestClient.swift#L15-L30`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/AppAttestClient.swift#L15-L30)
- **问题分析**：
  `sessionToken(baseURL:)` 包含多个 `await` 挂起点（`ensureKeyID`、`challenge`、`generateAssertion`、`post`）。当用户打开视频详情页或列表页时，多个 `MediaItem` 会并发调用 `UnifiedRatingsAPIClient.enrich`。在 Token 缓存未写入 `UserDefaults` 前，所有并发调用者同时通过有效期检查，各自独立发起完整的 challenge → assertion 握手流程。
- **影响**：产生 N 倍冗余服务器请求，可能触发断言计数器冲突或挑战消费竞争。
- **修复方案**：
  在 `AppAttestClient` 中维护 `private var inFlightTokenRefresh: Task<String?, Never>?`，合并并发的 token 刷新请求为单个共享 Task。

### 🟡 P1-3: `SMBAssetResourceLoader` 取消请求未终止后台读取循环
- **涉及文件**：[`Sources/MediaCore/PlaybackCore/SMBAssetResourceLoader.swift#L28-L60`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlaybackCore/SMBAssetResourceLoader.swift#L28-L60)
- **问题分析**：
  `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` 派发了异步 Task 分块读取 512KB 数据：
  ```swift
  Task { [reader] in
      // while remaining > 0 { reader.read(...) }
      loadingRequest.finishLoading()
  }
  ```
  而在 `resourceLoader(_:didCancel:)` 中没有任何取消逻辑（方法体为空）。当用户频繁拖动进度条（Scrubbing/Seek）或切换剧集时，已废弃的加载请求 Task 依然在后台继续向 SMB 服务器并发拉取大量数据，既浪费局域网带宽，又可能在已取消的 `loadingRequest` 上调用 `finishLoading()` 触发底层断言异常。
  **（复核补充）** 由于 `SMBRangeReader` 是 `actor`，所有读取操作序列化执行。僵尸请求的读取会排在新 seek 请求之前，导致严重的 seek 延迟或播放停滞。
- **修复方案**：
  在 `SMBAssetResourceLoader` 中维护 `[AVAssetResourceLoadingRequest: Task<Void, Never>]`，在 `didCancel` 中显式调用 `task.cancel()`，并在读取循环内增加 `if Task.isCancelled || loadingRequest.isCancelled { break }` 检查，且仅在未取消时调用 `finishLoading()`。

---

### 🟡 P1-4: `SOAPXMLHelper` 未实现 `parser(_:foundCDATA:)` 委托方法
- **涉及文件**：[`Sources/Receiver/SOAPParser.swift#L155-L193`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift#L155-L193)
- **问题分析**：
  许多 DLNA 控制器将 `CurrentURIMetaData` 包裹在 `<![CDATA[<DIDL-Lite>...</DIDL-Lite>]]>` 中。`Foundation.XMLParser` 通过 `parser(_:foundCDATA:)` 回调传递 CDATA 内容，而 `SOAPXMLHelper` 仅实现了 `parser(_:foundCharacters:)`，未实现 `parser(_:foundCDATA:)`。
- **影响**：来自部分投屏 App（如爱奇艺、腾讯视频、哔哩哔哩）的投送请求中，CDATA 包裹的 `CurrentURIMetaData` 字段将为空或不完整，导致无法识别投送的视频标题和播放地址。
- **修复方案**：
  ```swift
  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      if let string = String(data: CDATABlock, encoding: .utf8) {
          currentValue += string
      }
  }
  ```

---

### 🟡 P1-5: MPV 渲染定时器暂停时不停止，持续消耗 CPU 和电量
- **涉及文件**：[`Sources/MediaCore/PlaybackCore/MPVPlayerEngine.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlaybackCore/MPVPlayerEngine.swift)（`pause()` 方法和 `startRenderTimer()` 方法）
- **问题分析**：
  `pause()` 方法仅发送 `mivuMPVSetPaused(handle, 1)` 命令，但**不调用 `stopRenderTimer()`**。16ms 渲染定时器在暂停状态下仍以 60Hz 频率持续触发 `renderQueue` 上的渲染回调。渲染定时器仅在 `stop()` 或 `deinit` 时才被停止。
  此外，`mivuMPVHasNewFrame` 函数虽已导入（`@_silgen_name("mivu_mpv_has_new_frame")`），但从未在渲染循环中被调用来判断是否有新帧可渲染。
- **影响**：暂停播放时持续消耗 CPU 和电量，对移动设备续航产生不必要的负担。
- **修复方案**：
  在 `pause()` 中调用 `stopRenderTimer()`，在 `play()` 中调用 `startRenderTimer()`。可选地在 `timer.setEventHandler` 中先检查 `mivuMPVHasNewFrame` 以避免无效渲染。

### 🟡 P1-6: `PlayerService` 从不停用 `AVAudioSession`
- **涉及文件**：[`Sources/MediaCore/PlayerService.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlayerService.swift)
- **问题分析**：
  `setupAudioSession()` 在播放开始时调用 `try audioSession.setActive(true)`，但在播放停止、用户退出播放器或切换到其他 App 时，从未调用 `audioSession.setActive(false, options: .notifyOthersOnDeactivation)`。
- **影响**：其他音频应用（如 Apple Music、播客、Spotify）在 Mivu 停止播放后无法收到音频焦点释放通知，无法自动恢复播放。
- **修复方案**：
  在 `stop()` 或播放会话结束时调用 `setActive(false, options: .notifyOthersOnDeactivation)`。

### 🟡 P1-7: `UnifiedRatingsAPIClient` 在 `UserDefaults` 中缓存评分数据
- **涉及文件**：[`Sources/MediaCore/UnifiedRatingsAPIClient.swift#L47-L53`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/UnifiedRatingsAPIClient.swift#L47-L53)
- **问题分析**：
  评分 API 响应通过 `UserDefaults.standard.set(data, forKey: cachePrefix + lookup.cacheKey)` 缓存。`UserDefaults` 底层为 `Preferences.plist` 文件，会在进程启动时**整体加载进内存**。对于拥有数百甚至上千部媒体的用户，缓存的 JSON 数据会持续膨胀 plist 文件。
- **影响**：应用启动速度变慢，内存占用增大。
- **修复方案**：
  改用 `NSCache`（仅内存缓存）或轻量级持久化方案（如 SQLite / SwiftData）。

---

### 🟢 P2-1: MPV 渲染定时器中高频派发非结构化 Task
- **涉及文件**：[`Sources/MediaCore/PlaybackCore/MPVPlayerEngine.swift#L268-L270`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlaybackCore/MPVPlayerEngine.swift#L268-L270)
- **问题分析**：
  MPV 渲染定时器以 16ms（60Hz）的频率运行：
  ```swift
  timer.setEventHandler { [weak self] in
      if let unmanaged = mivuMPVRenderSampleBuffer(rawHandle, 0, 0) {
          let sampleBuffer = unmanaged.takeRetainedValue()
          target.enqueue(sampleBuffer)
          Task { @MainActor [weak self] in   // ⚠️ 每秒创建约 60 个 Task
              self?.onFrameRendered()
          }
      }
  }
  ```
  每秒调度 60 个 `Task` 到 `MainActor`，仅用于维护 `renderedFrameCount += 1` 和日志打印，造成了频繁的 Actor 线程切换与并发调度开销。
- **优化建议**：
  将 `renderedFrameCount` 改造为线程安全的原子计数或直接在渲染队列维护，仅在首帧渲染成功（`renderedFrameCount == 1`）需要配置字幕或状态变迁时单次通知主线程。

---

### 🟢 P2-2: `PlayerService` 主线程同步激活 `AVAudioSession` 引发卡顿
- **涉及文件**：[`Sources/MediaCore/PlayerService.swift#L159-L160`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlayerService.swift#L159-L160)
- **问题分析**：
  在主线程调用 `try audioSession.setActive(true)` 导致系统产生性能诊断日志：
  ```text
  [AVAudioSession Hang Risk] AVAudioSession_iOS.mm:978 This method can lead to UI unresponsiveness if called on the main thread. Consider using the asynchronous activate/deactivate API instead for calls from the main thread.
  ```
  **（复核补充）** `PlayerService` 标注为 `@MainActor`，`setupAudioSession()` 在 `loadAndPlay(...)` 中同步调用，且失败后的 `catch` 分支会**二次尝试** `try? AVAudioSession.sharedInstance().setActive(true)`，同样在主线程上阻塞。
- **优化建议**：
  改用 iOS 17+ 推荐的异步激活接口，或通过 `Task.detached(priority: .userInitiated)` 将音频会话激活移入后台：
  ```swift
  private func setupAudioSession() {
      Task.detached(priority: .userInitiated) {
          do {
              let audioSession = AVAudioSession.sharedInstance()
              try audioSession.setCategory(.playback, mode: .moviePlayback)
              try audioSession.setActive(true)
          } catch {
              try? AVAudioSession.sharedInstance().setCategory(.playback)
              try? AVAudioSession.sharedInstance().setActive(true)
          }
      }
  }
  ```

---

### 🟢 P2-3: `unescapeXML` 不支持数字字符实体
- **涉及文件**：[`Sources/Receiver/SOAPParser.swift#L140-L148`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift#L140-L148)
- **问题分析**：
  `unescapeXML` 仅处理 5 个基本 XML 实体（`&lt;` `&gt;` `&amp;` `&quot;` `&apos;`），不支持十进制数字实体（如 `&#20013;&#25991;`）和十六进制数字实体（如 `&#x4e2d;&#x6587;`）。
- **影响**：部分亚洲投屏客户端（爱奇艺、腾讯视频、哔哩哔哩）发送的包含 CJK 字符标题可能显示为原始实体码而非可读文字。
- **修复建议**：
  通过正则表达式匹配 `&#(\d+);` 和 `&#x([0-9a-fA-F]+);`，将其转换为对应的 Unicode 字符。

### 🟢 P2-4: `SOAPXMLHelper` 对 `depth == 3` 的脆弱假设
- **涉及文件**：[`Sources/Receiver/SOAPParser.swift#L169-L174`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift#L169-L174)
- **问题分析**：
  ```swift
  if depth == 3 && actionName.isEmpty && strippedName != "Body" && strippedName != "Envelope" {
      actionName = strippedName
  }
  ```
  如果 SOAP 请求在 `<s:Body>` 之前包含 `<s:Header>` 块（UPnP 1.1 标准允许），Header 内深度为 3 的元素会被错误捕获为 `actionName`（当 HTTP `SOAPACTION` 头缺失时）。
- **修复建议**：仅在父元素为 `Body` 时捕获 action name，通过维护父元素栈来判断上下文。

### 🟢 P2-5: Logger Subsystem 不一致
- **涉及文件**：[`Sources/Application/PhoneSceneDelegate.swift#L5`](file:///Users/kelvinsze/Projects/Mivu/Sources/Application/PhoneSceneDelegate.swift#L5)、[`Sources/Application/MivuApp.swift#L5`](file:///Users/kelvinsze/Projects/Mivu/Sources/Application/MivuApp.swift#L5)
- **问题分析**：
  多处代码使用 `Logger(subsystem: "com.kelvinsze.mivu", ...)` 而项目 Bundle ID 为 `com.kold.mivu`。
- **影响**：Console.app 或 Instruments 中按 Bundle ID 过滤日志时会遗漏这些条目。
- **修复建议**：将所有 Logger subsystem 统一为 `com.kold.mivu`，或定义全局常量引用 `Bundle.main.bundleIdentifier`。

---

## 4. 云端评分服务与硬件认证审计 (`ratings-api`)

### 🟡 P1-8: D1 数据库挑战码表（`app_attest_challenges`）无过期清理
- **涉及文件**：[`ratings-api/src/routes/app-attest.ts#L24-L32`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/routes/app-attest.ts#L24-L32)、[`ratings-api/migrations/0003_app_attest.sql`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/migrations/0003_app_attest.sql#L11-L17)
- **问题分析**：
  每次客户端发起 `/v1/app-attest/challenge` 均会向 `app_attest_challenges` 表插入一条包含 5 分钟有效期的记录。只有成功完成验证的请求会被 `DELETE`。如果客户端中途断网、放弃请求，或受到爬虫探测，未消费的记录将永久累积在 D1 数据库中。
  **（复核补充）** 当前 `wrangler.toml` 中无 `[triggers]` 配置，`src/index.ts` 中无 `scheduled` event handler。`expires_at` 字段上也没有索引。在恶意流量下（即使限流 60 req/min/IP），单个 IP 每天可产生 86,400 条未消费的挑战记录。
- **优化建议**：
  1. 新增迁移：`CREATE INDEX IF NOT EXISTS idx_challenges_expires ON app_attest_challenges(expires_at);`
  2. 在 `wrangler.toml` 添加 `[triggers]` 配置 Cron Trigger：`crons = ["0 * * * *"]`
  3. 在 `src/index.ts` 导出 `scheduled` handler，执行 `DELETE FROM app_attest_challenges WHERE expires_at < unixepoch()`。
  4. 可选地在 `/v1/app-attest/challenge` 路由中概率性触发清理（如每 10 次请求执行一次 `waitUntil` 后台清理）。

### 🟡 P1-9: `attestation.ts` X.509 证书链验证跳过有效期检查
- **涉及文件**：[`ratings-api/src/app-attest/attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts)（`validateChain` 函数）
- **问题分析**：
  `@peculiar/x509` 的 `X509ChainBuilder.findIssuer` 内部调用 `cert.verify({ publicKey, signatureOnly: true }, crypto)`。`signatureOnly: true` 表示**仅校验密码学签名，完全跳过 `notBefore` / `notAfter` 日期检查**。已过期的叶证书或中间证书仍会通过链验证。
- **影响**：理论上可使用已过期的证书完成设备认证（实际风险因 Apple Root CA 控制而较低，但不符合安全最佳实践）。
- **修复方案**：
  在 `validateChain` 中对链上每个证书手动检查 `cert.notBefore <= now && now <= cert.notAfter`。

### 🟡 P1-10: `attestation.ts` 中 `.buffer as ArrayBuffer` Buffer View 陷阱
- **涉及文件**：[`ratings-api/src/app-attest/attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts)（`sha256` 和 `validateChain` 函数）
- **问题分析**：
  ```typescript
  const digest = await crypto.subtle.digest('SHA-256', data.buffer as ArrayBuffer);
  const certs = x5c.map(der => new X509Certificate(der.buffer as ArrayBuffer));
  ```
  如果 `data` 或 `der` 是 CBOR 解码后 `Uint8Array.subarray()` 的结果，`.buffer` 返回的是**完整的底层 `ArrayBuffer`**（从 offset 0 开始），而非视图范围内的切片。`assertion.ts` 中此问题已被修复（使用 `pubkeyU8` 直接传递），但 `attestation.ts` 中仍未修复。
- **影响**：间歇性哈希计算错误或证书解析异常，导致合法设备认证失败。
- **修复方案**：
  使用 `data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)` 或直接传递 `Uint8Array`（workerd 接受 `BufferSource`）。

### 🟡 P1-11: 生产环境允许 Development AAGUID 认证
- **涉及文件**：[`ratings-api/src/app-attest/attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts)、`ratings-api/src/app-attest/session.ts`、`ratings-api/src/routes/ratings.ts`
- **问题分析**：
  `verifyAttestation` 接受 `AAGUID_DEV = 'appattestdevelop'` 并返回 `env: 'dev'`。下游的 `verifySessionToken` 和 ratings 路由均不检查 `appEnv === 'prod'`。
- **影响**：任何持有 Apple Developer 帐号的人都可以用开发签名的 iOS 二进制文件或模拟器/越狱设备获取 development attestation，并合法调用生产 Ratings API。
- **修复方案**：
  在 `/v1/app-attest/attest` 路由或 `verifyAttestation` 中添加环境检查：
  ```typescript
  if (c.env.ENVIRONMENT === 'production' && result.env === 'dev') {
      return createErrorResponse('FORBIDDEN', 'Development attestations are not permitted in production', 403);
  }
  ```

### 🛡️ 安全合规性与验证亮点
- **CBOR 与 X.509 逐级鉴权**：[`attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts) 完整实现了 WebAuthn/App Attest 验证规范，校验证书链完整终结于 Apple App Attest 根证书，有效杜绝了客户端伪造。（⚠️ 注意上述 P1-9 关于 `signatureOnly` 的补充）
- **重放攻击防御**：[`assertion.ts#L176-L191`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/assertion.ts#L176-L191) 在 D1 中以原子条件更新 `WHERE assertion_counter < newCounter`，严格保证断言计数器严格单调递增，彻底封死重放请求。经复核确认，D1/SQLite 串行写入保证了此操作的原子性。
- **请求级幂等防击穿**：[`ratings.ts#L48-L55`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/services/ratings.ts#L48-L55) 使用了 `RequestDeduplicator`，在 D1 查询前即拦截并发相同的冷启动请求。经复核确认，去重器为模块级单例，通过 `Map<string, Promise>` 合并同 key 并发请求。但注意其仅在单个 V8 isolate 内生效，跨边缘节点不共享状态。
- **SQL 注入防护**：经全面检查，所有数据库操作均使用参数化查询（`?` + `.bind(...)`），未发现 SQL 注入风险。

---

## 5. 权限、证书与分发合规性 (Entitlements & Compliance)

### 1. App Attest 环境硬编码为测试态
- **位置**：[`Mivu.entitlements#L9-L10`](file:///Users/kelvinsze/Projects/Mivu/Mivu.entitlements#L9-L10)、[`project.yml#L30`](file:///Users/kelvinsze/Projects/Mivu/project.yml#L30)
  ```xml
  <key>com.apple.developer.devicecheck.appattest-environment</key>
  <string>development</string>
  ```
- **注意**：提交 TestFlight 或 App Store 发布前，必须切换为 `production`（或在发布配置中移除该键，默认为生产环境），否则正式发布包将无法通过 Apple 生产 Attestation 服务器校验。

### 2. Apple 特殊权限审批前置
- 工程中声明了：
  - `com.apple.developer.carplay-audio`（车载音频播放）
  - `com.apple.developer.carplay-video`（车载视频播放）
  - `com.apple.developer.networking.multicast`（SSDP 本地组播）
- 上述权限均需在 Apple Developer Portal 提交专属表单审批通过后方可签发生产 Provisioning Profile，需提前准备好说明文档（工程中已包含良好的模板 [`docs/CARPLAY_ENTITLEMENT_APPLICATION.md`](file:///Users/kelvinsze/Projects/Mivu/docs/CARPLAY_ENTITLEMENT_APPLICATION.md)）。

### 3. 第三方开源许可（LGPL/GPL）
- 工程静态链接了 `libmpv.xcframework`，并依赖了 `FFmpeg` 与 `libass`。
- 确认构建脚本 [`scripts/build-libmpv-ios.sh`](file:///Users/kelvinsze/Projects/Mivu/scripts/build-libmpv-ios.sh) 排除了 GPL 组件，满足 LGPL 动态或静态链接重连义务，并妥善维护了 [`THIRD_PARTY_NOTICES.md`](file:///Users/kelvinsze/Projects/Mivu/THIRD_PARTY_NOTICES.md)。

### 4. `NSAllowsArbitraryLoads` 全局放行（复核补充）
- **位置**：[`Sources/Info.plist`](file:///Users/kelvinsze/Projects/Mivu/Sources/Info.plist)
- `NSAllowsArbitraryLoads = true` 全局开启了 HTTP 明文传输。虽然连接局域网 NAS（SMB/WebDAV/DLNA）需要 HTTP，但全量放行可能在 App Store 提审时触发额外说明问询。
- **建议**：搭配 `NSAllowsLocalNetworking: true` 并为外网域名配置 HTTPS 例外规则。

### 5. Entitlements 在 `project.yml` 中定义重复（复核补充）
- **位置**：[`project.yml#L27-L31`](file:///Users/kelvinsze/Projects/Mivu/project.yml#L27-L31)
- `project.yml` 既指定了 `path: Mivu.entitlements`（引用 .entitlements 文件），又显式在 `properties:` 中声明了相同的权限值。XcodeGen 会对两者进行合并/重写，容易产生不一致。
- **建议**：仅保留一处维护边界（推荐使用 `Mivu.entitlements` 文件，移除 `properties` 块）。

---

## 6. 目录结构与历史遗留清理建议

1. ~~**废弃工程删除**~~：
   - ~~根目录下残留的 `Vimu.xcodeproj` 属于早期更名前遗留目录。~~
   - ✅ **已完成**：经复核确认，`Vimu.xcodeproj` 已从文件系统中移除，当前仅保留 `Mivu.xcodeproj`。
2. **源码自嵌套重构**：
   - 当前存在 `Sources/Sources/PersonalMedia` 这种自嵌套路径（内含 `EmbyClient.swift`、`JellyfinClient.swift`、`MediaServerManager.swift`、`MediaServerProtocol.swift`、`SMBMediaClient.swift`、`WebDAVClient.swift` 共 6 个文件），以及同级的 `DLNASource.swift` 和 `URLSource.swift`。
   - 建议后续重构阶段将媒体源模块扁平化移入 `Sources/PersonalMedia` 或 `Sources/MediaSources`。

---

## 7. 云端服务基础设施补充 (Infrastructure)

### 🟢 P2-6: ratings-api 速率限制仅在单个 V8 isolate 内生效
- **涉及文件**：`ratings-api/src/middleware/rate-limit.ts`
- **问题分析**：
  `rateLimitMiddleware` 使用 isolate 内存中的 `Map<string, RateLimitRecord>()` 记录请求频率。在 Cloudflare Workers 全球分布式环境中，同一 IP 的请求命中不同边缘数据中心时，速率计数不会聚合。
- **影响**：攻击者可通过分布请求至不同网络路径绕过 60 req/min 限制。
- **建议**：引入 Cloudflare KV（已在 `wrangler.toml` 注释中预留）或 Durable Objects 实现跨隔离实例的计数。

### 🟢 P2-7: ratings-api 通配符 CORS 覆盖管理端点
- **涉及文件**：`ratings-api/src/index.ts`
- **问题分析**：
  所有路由（包括 `/v1/admin/*`）均设置 `origin: '*'`。
- **建议**：管理路由应限制 CORS 来源或仅接受内部来源。

---

## 8. 综合整改路线图 (Actionable Roadmap)

| 优先级 | 任务项 | 影响范围 | 解决措施 |
| :--- | :--- | :--- | :--- |
| 🔴 **P0** | 修复 DIDL-Lite 标题反转义 | UPnP 投送、单元测试 | 在 [`SOAPParser.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift) 中增加 `unescapeXML` 前处理 |
| 🔴 **P0** | 剥离 CarPlay 手机视图挂载（三处联动） | 车载场景、App Store 审核 | 移除 `PhoneSceneDelegate`、`AppDelegate`、`Info.plist` 中的 `UIWindowSceneSessionRoleCarPlay` 引用 |
| 🔴 **P0** | 修复 AppAttestClient 设备恢复后永久失效 | 评分功能完全瘫痪 | 在 Secure Enclave 操作失败时清除已缓存的 `keyIDKey` 并触发重新注册 |
| 🟡 **P1** | 评分 Token 401 自动失效与重试 | 评分服务可用性 | 在 [`UnifiedRatingsAPIClient`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/UnifiedRatingsAPIClient.swift) 增加 401 拦截与清退逻辑 |
| 🟡 **P1** | AppAttestClient 并发 Token 刷新去重 | 服务端负载、计数器冲突 | 维护 `inFlightTokenRefresh: Task<String?, Never>?` 合并并发请求 |
| 🟡 **P1** | SMB 加载请求支持显式 Cancel | 局域网带宽、播放响应 | 在 [`SMBAssetResourceLoader`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlaybackCore/SMBAssetResourceLoader.swift) 中管理 Task 句柄并处理 `didCancel` |
| 🟡 **P1** | SOAPXMLHelper 实现 `foundCDATA:` | 第三方投屏兼容性 | 在 [`SOAPParser.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift) 中追加 CDATA 委托方法 |
| 🟡 **P1** | MPV 暂停时停止渲染定时器 | 电量消耗 | 在 `pause()` 中调用 `stopRenderTimer()`，在 `play()` 中恢复 |
| 🟡 **P1** | AVAudioSession 停用处理 | 音频体验 | 在 [`PlayerService`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlayerService.swift) 停止播放时调用 `setActive(false)` |
| 🟡 **P1** | 评分缓存迁出 UserDefaults | 启动性能 | 在 [`UnifiedRatingsAPIClient`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/UnifiedRatingsAPIClient.swift) 改用 NSCache 或 SQLite |
| 🟡 **P1** | App Attest 挑战码过期清理 | D1 存储容量与查询性能 | 为 `ratings-api` 添加 Cron Trigger + `expires_at` 索引 |
| 🟡 **P1** | X.509 证书有效期验证 | 安全合规 | 在 [`attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts) `validateChain` 中手动检查日期 |
| 🟡 **P1** | `.buffer as ArrayBuffer` 视图修复 | 间歇性认证失败 | 在 [`attestation.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/app-attest/attestation.ts) 中正确切片 buffer |
| 🟡 **P1** | 生产环境拒绝 Development AAGUID | API 安全 | 在 [`app-attest.ts`](file:///Users/kelvinsze/Projects/Mivu/ratings-api/src/routes/app-attest.ts) 中添加环境检查 |
| 🟢 **P2** | MPV 渲染定时器去 Actor 调度 | 60Hz 渲染能耗与 CPU 开销 | 优化 [`MPVPlayerEngine.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/MediaCore/PlaybackCore/MPVPlayerEngine.swift) 帧统计逻辑为原子操作 |
| 🟢 **P2** | AVAudioSession 异步激活 | UI 卡顿 | 改用 `Task.detached` 或 iOS 17+ 异步 API |
| 🟢 **P2** | `unescapeXML` 支持数字实体 | CJK 标题显示 | 在 [`SOAPParser.swift`](file:///Users/kelvinsze/Projects/Mivu/Sources/Receiver/SOAPParser.swift) 增加 `&#...;` 解码 |
| 🟢 **P2** | SOAPXMLHelper action 捕获感知 Body | SOAP 解析健壮性 | 维护父元素栈判断上下文 |
| 🟢 **P2** | Logger Subsystem 统一 | 调试便利性 | 全部统一为 `com.kold.mivu` |
| 🟢 **P2** | `NSAllowsArbitraryLoads` 收窄 | 审核合规 | 搭配 `NSAllowsLocalNetworking` 并配置域名例外 |
| 🟢 **P2** | Entitlements 定义去重 | 工程配置一致性 | 移除 `project.yml` 中的 `properties` 块 |
| 🟢 **P2** | ratings-api 跨隔离实例速率限制 | API 安全 | 引入 KV 或 Durable Objects |
| 🟢 **P2** | ratings-api 管理端点 CORS 收窄 | API 安全 | 限制 `/v1/admin/*` 的允许来源 |
| 🟢 **P2** | App Attest 环境切换（发布前） | 生产认证 | 将 entitlements 切换为 `production` |
| ✅ 已完成 | `Vimu.xcodeproj` 清理 | 工程维护 | 已从文件系统移除 |
