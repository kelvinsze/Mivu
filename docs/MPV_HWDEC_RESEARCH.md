# Mivu libmpv iOS VideoToolbox 硬解调研

状态：调研与隔离重建完成，`ios-gl` 产物静态验证通过；真机 H.264 1920x960 Debug/Release 均已构建、安装并验收。当前 Debug/Release 均使用 `videotoolbox-copy`，Debug 播放日志与用户验收确认硬解及色彩正常。

## 结论

1. 隔离重建已启用官方 `ios-gl` 并通过静态验证；FFmpeg VideoToolbox
   decoder 与 mpv interop 均已编入产物。此前 `hwdec=auto-safe` 显示 `none` 的直接原因不是 FFmpeg 没有
   VideoToolbox，而是此前已安装的 `libmpv.a` **没有编译 VideoToolbox GPU
   interop driver**。此前构建脚本显式关闭了 `ios-gl`、`videotoolbox-gl` 和
   `videotoolbox-pl`；库内的 enabled-features 也没有这三项，且 archive
   没有 `hwdec_vt` / `hwdec_ios_gl` 对象。FFmpeg archive 中仍有
   `videotoolbox`、`h264_videotoolbox`、`hevc_videotoolbox` 符号，二者不矛盾。
   真机验证现确认 H.264 1920x960 Debug/Release 均以 `videotoolbox-copy` 硬解且色彩正常；零拷贝 `videotoolbox[nv12]` 路径偏绿，当前不采用。
2. mpv 0.40.0 已有官方 iOS OpenGL ES interop：
   [`video/out/hwdec/hwdec_ios_gl.m`](https://github.com/mpv-player/mpv/blob/v0.40.0/video/out/hwdec/hwdec_ios_gl.m)。它以 `EAGLContext` 和
   `CVOpenGLESTextureCache` 将 VideoToolbox 的 `CVPixelBuffer` 平面包装为
   mpv GL texture。因此不需要第三方 fork，也不应改用 macOS 的
   `videotoolbox-gl` 或 libplacebo/Vulkan 的 `videotoolbox-pl`。
3. 对当前 Mivu，最小变更是只将 mpv Meson 选项由
   `-Dios-gl=disabled` 改为 `-Dios-gl=enabled`；其余保持
   `-Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=disabled`，FFmpeg 继续
   `--enable-videotoolbox`。这会编入 `hwdec_ios_gl.m` 与 `hwdec_vt.c`，并由
   OpenGL Render API 注册 `ra_hwdec_videotoolbox`。**不能**仅把
   `videotoolbox-gl` 打开：在 iOS 上会选择 macOS 的 GL interop 源而非
   iOS 实现。也不能打开 `videotoolbox-pl`：上游要求 Vulkan 与 Metal-texture
   import，当前 Mivu 为 OpenGL ES。
4. 这是一条 Apple 已废弃但仍存在的 iOS-only API（iOS 12 起标记 deprecated），
   不是被当前 SDK 删除的 API。它可作为既有 OpenGL ES 渲染器的实验后端；不适用于
   visionOS/Catalyst，长期方向应是独立的 Metal 渲染架构，而非把本次实验扩大为迁移。

## 为什么 `auto-safe` 会回退为 `none`

mpv 的 `auto-safe` 是 `auto` 的别名；`videotoolbox` 和
`videotoolbox-copy` 均在上游白名单中。见 [mpv options
manual](https://mpv.io/manual/stable/#options-hwdec) 以及
[`vd_lavc.c` 的 autoprobe 表](https://github.com/mpv-player/mpv/blob/v0.40.0/video/decode/vd_lavc.c#L261-L281)。

但一个 decoder 只有在 renderer 能导入其硬件帧时才可用。mpv 的
[`video/out/gpu/hwdec.c`](https://github.com/mpv-player/mpv/blob/v0.40.0/video/out/gpu/hwdec.c#L42-L48)
仅在 `HAVE_VIDEOTOOLBOX_GL || HAVE_IOS_GL || HAVE_VIDEOTOOLBOX_PL` 时注册
`ra_hwdec_videotoolbox`。Mivu 当前三个 feature 都为 false，所以 `auto-safe`
找不到可用 interop，按手册回退软件解码，`current-hwdec` 即为 `none`。

本地可复核点：

- [`scripts/build-libmpv-ios.sh`](../scripts/build-libmpv-ios.sh) 当前仅启用 `ios-gl`；`videotoolbox-gl` 与 `videotoolbox-pl` 仍关闭。
- [`MPVBridge.m`](../Sources/MediaCore/PlaybackCore/MPVBridge.m) 使用
  `vo=libmpv`、Debug/Release `hwdec=videotoolbox-copy`，并在 `FILE_LOADED` 与
  `VIDEO_RECONFIG` 后读取 `hwdec-current`。
- 重建后的 `Frameworks/MPV/.../ios-arm64/libmpv.a` 已检出 `ios-gl=enabled`，且
  `ar -t` 包含 `hwdec_vt`/`hwdec_ios_gl`。

## 官方实现与 SDK 兼容性

上游 Meson 在 [`meson.build`](https://github.com/mpv-player/mpv/blob/v0.40.0/meson.build#L1406-L1412)
探测 OpenGL ES 3，然后在 [`L1482-L1502`](https://github.com/mpv-player/mpv/blob/v0.40.0/meson.build#L1482-L1502)
把 `ios-gl` 纳入 VideoToolbox driver。iOS 实现的运行时前提是：

- renderer 是 GL，且版本至少 GLES 2；
- 调用 interop 初始化时存在 current `EAGLContext`；
- `CVOpenGLESTextureCacheCreate` 成功。

这些检查可见于 [`hwdec_ios_gl.m`](https://github.com/mpv-player/mpv/blob/v0.40.0/video/out/hwdec/hwdec_ios_gl.m#L33-L111)。Mivu 在
load 前调用 `prepareSurfaceForLoading()`；它在 render queue 上创建 render context，
而 `mivu_mpv_init_renderer` 会 bind 自己的 GLES3（失败再 GLES2）`EAGLContext`，因此
顺序满足上游前提。此结论须在重建后以日志验证，不能替代真机结果。

Apple 当前 SDK 的
[`CVOpenGLESTextureCache`](https://developer.apple.com/documentation/corevideo/cvopenglestexturecache)
仍要求 GLES 2.0+ `EAGLContext`，可从 `CVImageBuffer` 建立 texture；但 API 被标为
deprecated（建议 Metal）。SDK header 同时说明它是 live binding：渲染前 buffer 必须
unlock，复用前应 `glFlush`。mpv 的 iOS mapper 保留 `CVOpenGLESTextureRef`，unmap 时释放并
flush cache，正符合该生命周期。当前项目的 Xcode SDK（iPhoneOS 27.0）以
`xcrun --sdk iphoneos clang -fsyntax-only` 对 `OpenGLES/ES3/glext.h` 和
`CoreVideo/CVOpenGLESTextureCache.h` 完成了无错误导入核查。

没有发现上游已合并的“必须换版本/特定 fork”修复：`v0.40.0` 和上游 `master` 都保留
同一 `ios-gl` feature 与 iOS mapper。应当固定当前已校验的 v0.40.0 commit，避免为此
硬解实验无关升级 mpv/FFmpeg。

## 最小、可复现的重建方案

保持现有下载 URL、tag、SHA-256、两 arm64 slice、iOS 17.0 deployment target、
`--wrap-mode nodownload` 和 FFmpeg codec/demuxer 白名单。不修改 app 代码，不升级依赖，
仅改 mpv feature 参数：

```text
-Dgl=enabled -Dplain-gl=enabled
-Dios-gl=enabled
-Dvideotoolbox-gl=disabled
-Dvideotoolbox-pl=disabled
```

现有 cross file 已提供 `c`、`cpp`、`objc` 均指向 iPhoneOS/iPhoneSimulator SDK 的 clang，
并传入 arm64 target、SDK 和最低系统版本；`hwdec_ios_gl.m` 只需要 Objective-C，故不需要
新增 toolchain 类型。app target 已链接 `CoreVideo`、`OpenGLES`、`VideoToolbox`，无需改
Xcode 链接项。

重建前的闸门：

1. 在隔离临时根目录运行脚本，保留现有 source archive SHA-256 检查；不得覆盖已知可用
   XCFramework，直到新产物完成下述静态检查。
2. 对 device 和 simulator 各检查 `meson-log.txt`/配置摘要包含 `ios-gl`，并确认 archive
   有 `hwdec_ios_gl`、`hwdec_vt`，没有意外的 `videotoolbox-pl`/Vulkan feature。
3. 用 `nm`/`strings` 确认 FFmpeg VideoToolbox decoder 仍在；`lipo`/`xcodebuild
   -create-xcframework` 确认 device 与 simulator 均为 arm64，headers 与现有 libmpv API 相同。
4. 仅在上述检查通过后，备份并替换 `Frameworks/MPV/libmpv.xcframework`，再做真机
   Debug 与 Release 构建；两者均以 `videotoolbox-copy` 验证硬解和色彩。

风险边界：此方案证明“可以构建并向 mpv 注册 VideoToolbox”，不保证任意文件、颜色格式、
内存压力或真机硬件资源一定可用。上游 iOS mapper 对不支持的 texture/pixel format 会失败；
OpenGL ES API 已废弃；另外，`auto-safe` 设计上允许可靠地退回软件解码。

## 真机验收清单

先验证不可回归：无论硬解是否成功，加载、暂停、seek、字幕、停止/重播均正常，并且失败时
不崩溃、不黑屏、不死锁，`current-hwdec=none` 时继续软件播放。

硬解成功的逐项证据：

1. 真机 Debug，确认 renderer 已在 `loadfile` 前初始化；播放 H.264 8-bit 和 HEVC 8-bit
   两个确定样本，各自记录 `MPV_HWDEC active=videotoolbox`、`vd=info` 的 decoder 日志和
   起播/seek 结果。
2. 另测 HEVC Main10/HDR（如产品声称支持），以及高码率和分辨率切换；检查颜色、范围、
   旋转、字幕叠加、截图与音画同步。不可把 H.264 通过外推为 10-bit/HDR 通过。
3. 前后台、锁屏恢复、来电/音频中断、网络短断重连、内存警告后重播；再分别确认 MPV 的
   AirPlay/PiP/CarPlay 仍按既有 AVPlayer 路由策略运行。
4. 最强的“实际硬件”证据不是仅看 `VTIsHardwareDecodeSupported`：Apple 明确说它不保证
   当时资源可用。应在创建的 VT session 上读取
   `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`，或以等效的 Apple
   工具证据记录。mpv public API 未暴露该 session，所以若发布门槛要求该级别证明，需另立
   小范围诊断改动；本次重建本身不能伪造此证据。

相关 Apple 一手资料：

- [`VTIsHardwareDecodeSupported`](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported%28_%3A%29)
- [`VTDecompressionSession` API](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession-api-collection)
- [`kCVPixelBufferOpenGLESCompatibilityKey`](https://developer.apple.com/documentation/corevideo/kcvpixelbufferopenglescompatibilitykey)

当前仅完成 H.264 1920x960 的真机播放验收；HEVC、HDR、高码率、后台与中断等范围仍需按
上列清单扩展验证，不能由本次结果外推。
