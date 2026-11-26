# 统一播放控制与实际断粮缓冲 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 有帧可显示时不再反复暂停音频，真正无帧才 rebuffer，并让用户暂停恢复与缓冲控制各司其职。

**Architecture:** `VideoJitterBuffer` 独占 playing/buffering 状态，低水位不再触发回缓冲，实际空队列经 0.12s 防抖才触发。`NativeBackend` 仅由 `onStateChange` 执行音频与 UI 副作用，用户暂停拥有最高优先级；保留设备时钟、插值缓存与设备采样率归一。

**Tech Stack:** Swift、SwiftPM、XCTest、PlayerKitNative、AudioQueue。

**Spec:** `Docs/superpowers/specs/2026-11-21-buffering-starvation-policy-design.md`

## Global Constraints

- 只改 PlayerKit；不改 zinora / PlayerKitPro / SyncController / 115 reader / UI smoothGrace。
- 保留 #66/#74/#77；用户暂停恢复不得重新引入 seek、flush 或队列重建。
- 一个 feature 一个 commit：最终 amend 当前分支提交；`git commit -s`，不得带 `Co-Authored-By`。
- 测试一律 `cd /Users/francis/workspc/PlayerKit && xcrun swift test`。
- 后台只通过 `DispatchQueue.main.async` 写 `state.isBuffering`；不得新增用户可见文案。
- 真断粮判定：播放中 `frames.isEmpty && !eofReached` 连续 **0.12s**；宽限预算仍为 4.0s / 0.5s。
- 最终删除全部 `TEMP-DIAG` 临时 NSLog。

## Review Focus

- **低水位但有帧**：不得改变状态或触发回调；Task 1 `testLowDurationWithFramesDoesNotRebuffer`。
- **短暂单帧间隙**：0.12s 内恢复供给不得 rebuffer；Task 1 `testAppendWithinStarvationDebounceAvoidsBuffering`。
- **EOF 末尾排空**：不得因空队列回缓冲；Task 1 `testEOFEmptyBufferDoesNotRebuffer`。
- **缓冲中用户暂停**：jitter 放行不得恢复音频；Task 2 `testAudioResumeIsRejectedWhileUserPaused`。
- **启动/seek 初始 buffering**：高水位、EOF、宽限仍必须放行；Task 1 既有测试改编后逐项覆盖。
- **真实持续供给不足**：允许整段 rebuffer，不得通过隐藏缓冲卡伪装流畅；Task 1 `testStarvedBufferRecoversOnlyAtResumeDuration`。

---

### Task 1: `VideoJitterBuffer` 实际断粮状态机

**Files:**
- Modify: `Sources/PlayerKitNative/VideoJitterBuffer.swift`
- Test: `Tests/PlayerKitTests/VideoJitterBufferTests.swift`

**Interfaces:**
- Consumes: 现有 `now: () -> TimeInterval`、`resumeDurationLocked`、`eofReached`、`onStateChange`。
- Produces: `func pollStarvation()`，供 Task 2 每个 display tick 调用；`State.playing/.buffering` 语义不变。

- [ ] **Step 1: 写失败测试**

新增并改编测试，全部使用注入假墙钟：
1. `testLowDurationWithFramesDoesNotRebuffer`：两帧达到 playing 后 pop 到只剩一帧，duration=0 仍 playing、无 buffering 回调。
2. `testStarvationRequiresDebounce`：弹出最后一帧后，0.11s poll 仍 playing，0.12s poll 转 buffering 且回调仅一次。
3. `testAppendWithinStarvationDebounceAvoidsBuffering`：空队列 0.05s 后 append，随后 poll 不转 buffering。
4. `testStarvedBufferRecoversOnlyAtResumeDuration`：真实断粮后仅 append 0.04s 内容不放行，达到 resume 水位才 playing。
5. `testEOFEmptyBufferDoesNotRebuffer`：markEOF 后排空并推进 1s，仍 playing。
6. 既有宽限测试中的「pop 到低水位」改为「排空 + 0.12s poll」，断言首次 4s、降级 0.5s、健康恢复 re-arm 不变。
7. 删除 `secondsSinceLastAppend` 测试及旧 `testTransitionsToBufferingWhenBelowMinDuration` 语义。

- [ ] **Step 2: 运行并确认 RED**

Run: `xcrun swift test --filter VideoJitterBufferTests`
Expected: 低水位仍误进 buffering，`pollStarvation` 尚不存在导致编译失败；记录实际输出。

- [ ] **Step 3: 实现最小状态机**

- 新增 `private var starvingSince: TimeInterval?` 与 `private let starvationDebounce: TimeInterval = 0.12`。
- `pop` 删除 `dur < minDurationLocked` 回缓冲分支；保留 `dur >= resumeDurationLocked` 时宽限预算 re-arm。
- 新增 `func pollStarvation()`：锁内检查 playing、非 EOF、空队列；首次记录 starvingSince，连续达到 0.12s 才转 buffering 并重置 bufferingStart；非空/非 playing/EOF 清空 starvingSince；锁外发一次 onStateChange。
- append、markEOF、flush 清理 starvingSince；删除 C-b 专用 `lastAppendAt`、`secondsSinceLastAppend`、`minDurationForPolicy`、`resumeDurationForPolicy` 及已无消费者的 minDuration 计算。

- [ ] **Step 4: 运行并确认 GREEN**

Run: `xcrun swift test --filter VideoJitterBufferTests`
Expected: 全部通过，且新测试名均出现在 `Test Case ... passed` 行。

---

### Task 2: `NativeBackend` 统一音频/UI 仲裁与暂停恢复清理

**Files:**
- Modify: `Sources/PlayerKitNative/NativeBackend.swift`
- Create: `Tests/PlayerKitTests/NativeBackendBufferingControlTests.swift`
- Delete: `Sources/PlayerKitNative/BufferingPolicy.swift`
- Delete: `Sources/PlayerKitNative/AudioBufferingHealth.swift`
- Delete: `Tests/PlayerKitTests/BufferingPolicyTests.swift`
- Delete: `Tests/PlayerKitTests/AudioBufferingHealthTests.swift`

**Interfaces:**
- Consumes: Task 1 `jitterBuffer.pollStarvation()`。
- Produces: `nonisolated func setAudioPaused(_ paused: Bool)`（internal，供同模块测试验证用户暂停优先级）；无其他新 API。

- [ ] **Step 1: 写用户暂停优先级失败测试**

用实现 `AudioOutputBackend` 的 recording fake 创建 `NativeBackend(audioOutput:)`：
1. 未暂停时 `setAudioPaused(false)` 调用 fake.resume。
2. `backend.pause()` 后调用 `setAudioPaused(false)`，fake.resume 计数不得增加。
3. `stop()` 重置用户暂停标记后允许恢复；测试结束 stop 清理资源。

- [ ] **Step 2: 运行并确认 RED**

Run: `xcrun swift test --filter NativeBackendBufferingControlTests`
Expected: 当前 `setAudioPaused` 为 private，测试编译失败；不得通过删除断言绕过。

- [ ] **Step 3: 收口实现**

- `wireJitterBuffer` 改为单一 switch：buffering → 暂停音频 + UI true；playing → 恢复音频 + UI false；systemDVActive 跳过。
- `displayNextFrame` 用 `jitterBuffer.pollStarvation()` 替换 `reconcileBufferingState()`。
- 删除 `BufferingPolicy`、`AudioBufferingHealth` 及 reconcile/policySessionPlaying 全部代码。
- 保留 `setAudioPaused(false)` 的 `userPausedForPolicy` 防护；open/stop 重置 UI 上报与用户暂停标记。
- 删除 `pausedClockPosition` 属性及 pause/resume 中无效写入；用户 resume 保持现有 AudioQueuePause/Start，不新增 seek/flush。
- 删除临时 `[PK]` NSLog；保留必要 os.Logger 状态切换日志，每 tick 不打日志。

- [ ] **Step 4: 运行定向回归**

Run: `xcrun swift test --filter 'NativeBackendBufferingControlTests|VideoJitterBufferTests|BufferingStabilityTests|ResumeAVSyncTests|AudioDeviceDomainTests'`
Expected: 全绿；若 pacing 回归失败，先查是否仍有低水位音频暂停，不修改测试阈值。

---

### Task 3: 全量验证、文档与真机

**Files:**
- Modify: `Docs/superpowers/specs/2026-11-21-buffering-starvation-policy-design.md`（如实现偏差回写）
- Modify: `Docs/superpowers/plans/2026-11-21-buffering-starvation-policy.md`

- [ ] **Step 1: 全量测试与差异审查**

Run: `xcrun swift test`
Expected: `Executed N tests ... 0 failures`；检查 git diff 无 BufferingPolicy/catchUp/TEMP-DIAG 残留、无无关文件。

- [ ] **Step 2: 构建并安装真机**

沿用 ZinoraApple Release、build 78、既有 DerivedData 缓存与设备 `00008130-001461243401001C`；安装后用 `--terminate-existing` 启动。

- [ ] **Step 3: 真机验收**

验证同一 4G 大秦帝国、44.1k 1080p、断网恢复、播放中与缓冲中暂停恢复。预期有帧时不再出现每分钟几十次音频停走；持续供给不足时允许正常缓冲卡。

- [ ] **Step 4: 单提交收尾**

确认 staged 完整列表后将全部源码/测试/文档 amend 到当前 feature commit，`git commit -s --amend --no-edit`；推送更新 PR #78 前向用户展示新提交与 PR 说明，征得同意后推送并复查 CI/审查评论。
