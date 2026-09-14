# MPV 真机验收记录

本文件是 MPV 路由扩大或发布前的唯一验收清单。模拟器、单元测试、archive
构建和源码阅读都不能替代其中任一项。

## 固定前提

- 记录 App commit、iPhone 型号、iOS 版本、服务端版本和测试日期。
- 使用实际安装到 iPhone 的包，并确认诊断日志含 `LOAD ... engine=MPV`。
- 受保护媒体仅记录 Header 名称、HTTP 状态和请求 ID；不得记录 Token、Cookie
  或完整私有 URL。
- 每一行附一段屏幕录像或截图，以及对应的脱敏服务端日志/播放器诊断。

## 非原生容器收益

| 项目 | 测试动作 | 通过条件 | 必留证据 | 结果 |
| --- | --- | --- | --- | --- |
| MKV 渲染 | 播放 H.264/AAC MKV 两分钟 | 首帧、音画、暂停/恢复正常，无黑屏 | `LOAD`、`MPV_RENDER`、录像 | 待测 |
| WebM 渲染 | 播放 VP9/Opus WebM 两分钟 | 同上 | 同上 | 待测 |
| 嵌入 ASS | 切换中文 ASS，调整延迟与位置 | 无 tofu，样式、延迟、位置生效 | 前后截图、`MPV_SID` | 待测 |
| 外置字幕 | 受 Header 保护的 SRT/ASS | 请求携带 Header，字幕可见 | 服务端 2xx/401 对照、`MPV_SUB_ADD` | 待测 |
| 鉴权 Header | 播放须鉴权的 MKV/WebM | 服务端收到预期 Header；移除后为 401/403 | 脱敏访问日志 | 待测 |
| Seek | 10→60→10 秒，各三次 | 目标误差不超过 2 秒，音画恢复 | 录像、`SEEK_COMPLETED` | 待测 |
| 后台 | 播放后锁屏/切后台 60 秒再返回 | 无崩溃或重载；记录后台前后时间点 | `LIFECYCLE` 两条日志、录像 | 待测 |

## 平台能力边界

| 能力 | MPV 试验 | 通过定义 | 未通过时的发布策略 | 结果 |
| --- | --- | --- | --- | --- |
| VideoToolbox 硬解 | 仅实验构建，分别测 H.264 与 HEVC | 日志可证明硬解或可靠软解回退且连续播放 | 保持生产 `hwdec=no` | 待测 |
| AirPlay | 对 MPV MKV/WebM 发起投屏 | 连接、画面、音频、断连恢复均正常 | 检测到 AirPlay 路由时重启为 AVPlayer | 当前固定 AVPlayer |
| PiP | 对 MPV MKV/WebM 进入/退出 PiP | 进入、返回、锁屏恢复均正常 | PiP 仅 AVPlayer | 当前固定 AVPlayer |
| CarPlay | 连接实体车机播放 MPV 候选媒体 | 车机视频、控制、重连、后台都正常 | 连接或从车机选择时固定 AVPlayer | 当前固定 AVPlayer |

生产版本不得把未填为“通过”的能力宣称为支持，也不得因 codec、外置字幕、
AirPlay、PiP 或 CarPlay 意图而扩大 MPV Router。完成一轮验收后，将“结果”
替换为通过/失败、证据路径和 commit；失败项维持右列策略。
