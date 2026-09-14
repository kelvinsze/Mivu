# libmpv / FFmpeg / libass 分发审查

状态：**未批准发布**。本记录完成了当前构建输入与许可证风险盘点；静态合并
产物的最终分发批准必须由发布负责人（必要时法务）基于实际 release 二进制签署。

## 已核对的构建事实

| 组件 | 当前构建输入 | 上游许可证线索 | 当前结论 |
| --- | --- | --- | --- |
| mpv 0.40.0 | `-Dgpl=false`、静态 `libmpv.a` | LGPL-2.1+ 模式仅在未使用 GPL-only 源码时可能成立 | 不可仅凭 flag 放行 |
| FFmpeg 7.1.3 | `--disable-gpl --disable-nonfree`、静态合并 | 默认 LGPL-2.1+；可选 GPL 部分会改变整体义务 | 需按最终配置与链接方式审查 |
| libass 0.17.5 | 静态，CoreText | ISC | 需保留版权及许可文本 |
| WenQuanYi Micro Hei | `subfont.ttf`，SHA-256 见 Notices | 字体内元数据标示 Apache-2.0 | 需随包提供 NOTICE/许可文本 |

相关上游材料：

- [mpv Copyright](https://github.com/mpv-player/mpv/blob/v0.40.0/Copyright)
- [FFmpeg License and Legal Considerations](https://ffmpeg.org/legal.html)
- [libass COPYING](https://github.com/libass/libass/blob/0.17.5/COPYING)

## 发布阻断项

1. 从最终构建导出实际链接输入、配置行、补丁和所有静态归档的 SBOM；逐项覆盖
   libplacebo、FreeType、HarfBuzz、FriBidi、zlib、iconv、libc++ 与字体。
2. 保留与二进制完全对应的源码归档、构建脚本、SHA-256、修改补丁和 source-offer
   URL；不得只链接到会漂移的默认分支。
3. 就静态合并 LGPL 组件的可重链接/替换义务取得书面结论。FFmpeg 的官方清单将
   动态链接列作最简单合规路径；当前 iOS 静态合并产物不能据此自动视为合规。
4. 在 App 的“关于”页、下载页和 EULA 中加入第三方组件、许可证、版权和源码取得
   方式；将 libass ISC 与 WenQuanYi Apache-2.0 的全文纳入随包 Notices。
5. 复核 codec 专利、出口、App Store 规则和目标发行地区；这些均不由开源许可证
   审查替代。

完成全部阻断项并由发布负责人签署前，`THIRD_PARTY_NOTICES.md` 只能视为构建
输入清单，不能视为 App Store 分发许可。
