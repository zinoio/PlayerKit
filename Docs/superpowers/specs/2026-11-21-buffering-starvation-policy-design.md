# 统一播放控制与实际断粮缓冲设计

- 日期：2026-11-21
- 仓：PlayerKit
- 状态：已批准（用户选择方案 B 并授权直接实现）
- 关联：#66（暂停恢复设备时钟）、#74（设备时钟插值）、#75（bufferingStart）、#77（设备采样率）、PR #78

## 1. 背景与根因

#66 将 PCM 主时钟改为 AudioQueue 设备播放位置，并使用 AudioQueuePause/Start 实现用户暂停恢复；#74 以插值缓存降低设备查询成本；#77 将解码器输出重采样到设备采样率，解决 44.1kHz 内容与 48kHz 设备的时钟域错位。这些修复保留，不回退。

C-b 试验在正常播放中引入第二套音频 pause/resume 控制：视频低于 minDuration 时进入 catchUp，短暂停顿后恢复。2026-11-21 真机日志证明其结构失效：

- 28.6s 内进入 catchUp 45 次（约 94 次/分钟）；
- 持续时间中位数 0.118s、最长 0.445s，因此「0.5s 未恢复则升级 classic」一次也未执行；
- 缓冲仍有 q=7–9 帧、帧仍在到达、音频余量健康，但音频时钟仅以实时 0.53×/0.63× 前进；
- CI 一轮 `AVSyncJitterMeasurementTests` 出现 pacing collapse。

根因不是某个阈值，而是**低水位预警被错误地当成运输暂停条件，且 jitter 与 BufferingPolicy 两个状态机共同拥有音频停走权**。

## 2. 目标 / 非目标

### 目标

1. 有帧可显示时，绝不因缓冲时长低而暂停音频或显示缓冲卡。
2. 真正无帧可显示且持续超过短防抖才 rebuffer；恢复仍走高水位、EOF 或宽限。
3. 用户暂停、rebuffer、系统 DV 路径职责分离；音频运行状态只有一个仲裁入口。
4. 用户暂停/恢复不 seek、不 flush、不重建队列，保留 #66/#74/#77 行为。
5. 删除 catchUp、音频余量参与暂停决策及失效的 `pausedClockPosition` 状态。

### 非目标

- 不修改 SyncController 的 freeze-ahead/skip-behind 算法。
- 不修改 115 reader、VT/软解速度、UI 文案与 BufferingIndicator 的 2.5s smoothGrace。
- 不承诺在持续带宽低于码率时完全无缓冲；此时必要的整段 rebuffer 是正确行为。
- 不做 AudioUnit 替换 AudioQueue 的独立重构。

## 3. 方案比较

| 方案 | 行为 | 结论 |
|---|---|---|
| A 继续修 C-b 阈值 | 调 catchUp 冷却、迟滞、classic 升级条件 | 拒绝：仍有两个状态机拥有音频停走权，只改变抖动频率 |
| **B 统一运输控制 + 实际断粮缓冲（选定）** | 有帧不停音频；真空持续 120ms 才 rebuffer；高水位恢复 | 消除根因，保留现有暂停恢复与设备时钟成果 |
| C 全面重写音频输出/时钟 | 同时迁移 AudioUnit、新时钟栈 | 超出本问题范围，风险与验证成本过高 |

## 4. 状态与职责

### 4.1 用户运输意图

`playing` / `userPaused` 只由公开 `play` / `pause` / `resume` / `stop` 控制。用户恢复不 seek、不 flush、不重建队列。`pausedClockPosition` 已无消费者，删除。

### 4.2 缓冲状态

`VideoJitterBuffer` 仍是唯一 playing/buffering 状态拥有者：

- 初始/flush 后为 `.buffering`。
- 播放中剩余时长低于 `minDuration` **不再改变状态**：这是预警，不是断粮。
- 播放中队列变空时记录 `starvingSince`；显示 tick 调 `pollStarvation()`，连续空 ≥ **0.12s** 才转 `.buffering`，同时重置 `bufferingStart`。
- 防抖窗口内又有帧到达则清除 `starvingSince`，不产生任何音频/UI 副作用。
- EOF 不因空队列进入 rebuffer，末尾帧正常放完。
- `.buffering` 中，append 在时长 ≥ `resumeDurationLocked`、EOF 或有效宽限到期时转 `.playing`。
- 宽限恒定 4s（2026-11-21 真机修订：降级 0.5s 闩在供给不足时反作用——缓冲刚攒就被强开，dur=0/q=1，形成 0.5-1.5s 微循环。恒定 4s 让涓流真正攒到水位或宽限再开门）。
- 放行水位 1.5s（2026-11-21 真机修订，探针轮 F/G 定案）：4K VBR 高码率场景（~8Mbps 段）遇通道到达率缺口（实测 ~6Mbps ≈ 0.8×）时，原 1.0s 水位（实开 ~0.86s）每 ~4.5s 必然触底；容量（iOS 512MB ≈ 41 帧 ≈ 1.64s @25fps）允许更深吸收，加深到 1.5s 让缓冲吃掉 CDN 突发间隙。G 轮对照同设备同网络 45s+ 零断粮、25fps 间隔均匀——管线无回归，差距全在缓冲深度对缺口的吸收能力。代价：起播首开慢 ~0.6s（4s 慢解码宽限兜底）。

### 4.3 音频与 UI 仲裁

`NativeBackend` 仅由 `jitterBuffer.onStateChange` 驱动缓冲副作用：

- `.buffering`：`setAudioPaused(true)` + `requestUIBuffering(true)`；
- `.playing`：`setAudioPaused(false)` + `requestUIBuffering(false)`；
- `setAudioPaused(false)` 在用户暂停时拒绝执行，不能顶掉用户意图；
- UI 只在值变化时 dispatch main 写 `state.isBuffering` 并通知；
- 系统 DV 路径继续绕过 jitter 控制；
- 音频余量、append 进度不再作为独立暂停条件。

`AudioUnitOutput` 继续拥有设备时钟；`AudioClock` 保留为 seek/reset 锚与设备时钟不可用时的回退，不新增第三个主时钟。

## 5. 主要改动

- `VideoJitterBuffer.swift`：删除低水位回缓冲；新增实际空队列防抖、poll；宽限恒定 4s（删降级闩）；放行水位 1.0s → 1.5s。
- `NativeBackend.swift`：删除 `BufferingPolicy` 每 tick reconcile、音频余量判定、`policySessionPlaying`；onStateChange 统一执行音频/UI；display tick 仅 poll 真空；删除 `pausedClockPosition` 与临时诊断 NSLog。
- 删除 `BufferingPolicy.swift`、`AudioBufferingHealth.swift` 及对应测试。
- `VideoJitterBufferTests.swift`：覆盖低水位继续播放、真空防抖、防抖内恢复、真实断粮高水位恢复、EOF、宽限预算。
- 现有暂停恢复、设备时钟域、BufferingStability、全量测试保持绿。
- 无 zinora 侧改动。

## 6. 验证与验收

### 单元 / 集成

1. 有帧但 duration < minDuration：状态与回调均不变。
2. 最后一帧弹出后 <0.12s：仍 playing；≥0.12s：一次 buffering 回调。
3. 空队列防抖内 append：不进入 buffering。
4. buffering 后 append 不放行；达到 resume 水位（1.5s）才 playing。
5. EOF 空队列不进入 buffering。
6. 宽限恒定 4s：3s 有帧不放行，4s 有帧放行；第二次断粮同样等满 4s（不降级）。
7. 用户暂停期间 jitter 放行不得恢复音频。
8. 全量 `xcrun swift test` 绿；CI 不得再出现本次策略导致的 pacing collapse。

### 真机

- 同一 4G 大秦帝国：有帧时音频不反复停顿；真供不上时显示整段缓冲而非无声高频抖动。
- 大秦赋 44.1k 1080p：25fps 匀速，暂停/恢复落点不漂。
- 断网：缓冲卡出现；恢复网络后继续。
- 缓冲中用户暂停/恢复：不擅自发声，不错误清播放位置。
- 日志只剩 jitter 状态切换；不得出现每分钟几十次音频 pause/resume。

## 7. 风险

- 持续供给低于实时时仍会周期性 rebuffer，这是必要行为；若真机仍卡，需另查吞吐/解码，不再用策略掩盖。
- 0.12s 防抖是初始值，以单帧间隙不误停、真断粮及时反馈为验收标准；如需调整，只改这一处并有测试支撑。
- `requestUIBuffering` 的 main.async 陈旧写属于既有小竞态，本版通过会话开始/结束重置上报值，不扩大处理范围。
