# PlayerKit Project Guidelines

## Communication & Git

- Always reply in Chinese (Simplified).
- Use `xcrun swift build` and `xcrun swift test` (never bare `swift`, which is OpenStack CLI on this machine).
- Single commit per feature, always `git commit -s`, never add `Co-Authored-By`, never amend or rebase existing commits.
- Keep open-source boundary: never add closed-source or Pro-only dependencies (`PlayerKitPro`) here.

## 目录结构速查（减少搜索范围）

| 路径 | 职责 |
|------|------|
| `Sources/PlayerKit/` | 公开协议、状态模型、视图入口、平台适配抽象与渲染接口 |
| `Sources/PlayerKitNative/` | 核心原生播放引擎：`NativeBackend*.swift`（管线/解复用/同步/切轨）、`FFmpeg*`（解复用/音视频/字幕解码）、`AudioUnitOutput.swift` / `PCMRingBuffer.swift` / `AudioClock.swift`、`VideoJitterBuffer.swift` / `VT*` / `Metal*` |
| `Sources/CFFmpeg/`、`Sources/CAss/` | FFmpeg 与 libass C 桥接模块及预编译 xcframework |
| `Tests/PlayerKitTests/` | 框架核心单元测试（同步、缓冲、音频输出、解复用、切轨等） |
| `Examples/MinimalPlayer/` | macOS 独立 SPM 示例 App |
| `Docs/`、`scripts/` | 架构/调试文档与构建脚本（`build_ffmpeg.sh`、`build_libass.sh` 等） |

> 搜索代码时默认**跳过**：`build/`、`.build/`、`Sources/*/xcframeworks/`（二进制产物）。
