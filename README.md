# PlayerKit

A protocol-oriented, FFmpeg + VideoToolbox + Metal media player SDK for Apple platforms (macOS / iOS / tvOS).

PlayerKit gives you a production-grade playback pipeline — native hardware decoding, A/V sync, HDR → SDR tone-mapping — behind a clean protocol surface. Bring your own renderer, audio output, or frame sink by conforming to a protocol. No lock-in, no global state.

![MinimalPlayer](Examples/MinimalPlayer/Screenshots/main.png)

## Features

- **Protocol-oriented core** — `Playable` / `MediaProbable` / `VideoRenderer` / `AudioOutputBackend` / `FrameSink` / `PlayerBackend`. Replace any piece by conforming to a protocol.
- **Native hardware decoding** — VideoToolbox (VT) for H.264 / HEVC, FFmpeg software decoder as fallback for other codecs. Audio is decoded via FFmpeg (AAC, Opus, AC3, EAC3, DTS, TrueHD, FLAC, ...) and driven by a Pull-mode `AudioUnitOutput` + lock-free `PCMRingBuffer`.
- **A/V sync** — AudioClock-driven master clock, VideoJitterBuffer (PTS-ordered), SyncController, PTSValidator. Tuned for variable-frame-rate and seek-resume.
- **Native ASS/SSA subtitles** — Bundled `libass` (`CAss`, CoreText font provider) plus PGS/VOBSUB bitmap subtitle overlay.
- **HDR → SDR tone-mapping & Dolby Vision pipeline** — BT.2390 EETF for PQ/HLG inputs, BT.2020 → BT.709 gamut conversion in Metal (`Shaders.metal::hdr_to_sdr`), plus Dolby Vision RPU/NLQ metadata extraction and Profile 7 FEL dual-track EL decoding.
- **FFmpeg & libass bundled** — Prebuilt xcframeworks (`libavcodec`/`libavformat`/`libavutil`/`libswresample`/`libswscale` and `libass`/`freetype`/`fribidi`/`harfbuzz`). On the `zinoio/PlayerKit` repository they are committed; rebuild locally with `scripts/build_ffmpeg.sh` and `scripts/build_libass.sh`.
- **Open Core** — Base player is open-source (LGPL v2.1+). Advanced EDR/HDR passthrough, Dolby Vision Profile 5/7 FEL (NLQ Metal shader)/8 rendering, Atmos/DTS-HD passthrough, DLNA cast, Audio DSP, and AI frame sampling live in the closed-source `PlayerKitPro` module, injected via the same protocols.

## Requirements

- macOS 14.0+ / iOS 17.0+ / tvOS 17.0+
- Xcode 16+
- Swift 5.9+

## Quick Start

```swift
import SwiftUI
import PlayerKit
import PlayerKitNative

struct ContentView: View {
    @State private var player: Player?

    var body: some View {
        ZStack {
            if let player {
                PlayerNativeView(player: player)
            } else {
                Color.black
            }
        }
        .task {
            do {
                let backend = try NativeBackend()
                player = Player(backend: backend)
                player?.play(url: URL(string: "https://example.com/movie.mkv")!)
            } catch {
                print("init failed: \(error)")
            }
        }
    }
}
```

`NativeBackend()` defaults to a SDR `MetalRenderer` + `AudioUnitOutput` (PCM). For HDR inputs, the renderer tone-maps to SDR automatically. Playback state (`isPlaying` / `position` / `duration` / `error` / ...) is observable via `player.state` — bind your UI to it directly.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/zinoio/PlayerKit.git", from: "0.1.0"),
]
```

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "PlayerKit", package: "PlayerKit"),
    .product(name: "PlayerKitNative", package: "PlayerKit"),
])
```

FFmpeg and libass xcframeworks are committed to the `zinoio/PlayerKit` repository
for zero-setup SPM integration. To rebuild them from source locally, run
`scripts/build_ffmpeg.sh` and `scripts/build_libass.sh`.

## Examples

See [`Examples/MinimalPlayer/`](Examples/MinimalPlayer/) — a macOS demo app with file open panel, URL overlay, play/pause, seek bar, volume, fullscreen, and an error overlay with copy-to-clipboard. It demonstrates the typical SwiftUI integration shape (`PlayerNativeView` + `Player.state` binding).

```bash
cd Examples/MinimalPlayer
xcrun swift run
```

> The `swift run` binary alone won't activate the AppKit GUI — bundle it into a `.app` and `open` it. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the exact steps.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your App                                       │
│  ┌──────────────────────────────────────────┐  │
│  │  Player (facade)                         │  │
│  │  └─ PlayerBackend (protocol)             │  │
│  │     ├─ VideoRenderer (protocol)          │  │
│  │     ├─ AudioOutputBackend (protocol)     │  │
│  │     └─ [FrameSink] (protocol)            │  │
│  └──────────────────────────────────────────┘  │
│                                                 │
│  Default implementations (PlayerKitNative):     │
│  ┌──────────────────────────────────────────┐  │
│  │  NativeBackend                           │  │
│  │  ├─ MetalRenderer  : VideoRenderer       │  │
│  │  ├─ AudioUnitOutput: AudioOutputBackend  │  │
│  │  ├─ FFmpegDemuxer                        │  │
│  │  ├─ VTVideoDecoder / FFmpegVideoDecoder  │  │
│  │  └─ SyncController / AudioClock / ...    │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### Open Core boundary

The open-source `PlayerKit` + `PlayerKitNative` targets cover:

- Protocol layer (`Playable` / `MediaProbable` / `FrameSink` / `VideoRenderer` / `AudioOutputBackend` / `PlayerBackend`)
- `NativeBackend` (VT hardware decode + FFmpeg software decode + Metal SDR rendering + A/V sync + basic HDR → SDR tone-mapping)

The closed-source `PlayerKitPro` module provides:

- `EDRRenderer` — HDR passthrough to EDR/HDR displays with dynamic tone-mapping
- Dolby Vision rendering (Profile 5, Profile 7 FEL via NLQ Metal shader, Profile 8)
- `PassthroughOutput` — Atmos / DTS-HD compressed audio passthrough (AC3/EAC3/DTS)
- `DSPOutput` — Real-time audio DSP processing (EQ / voice clarity / night mode)
- `DLNAFrameSink` — Cast to DLNA renderer devices
- `AIFrameSampler` — Sample frames for OCR / scene detection / subtitle translation

`PlayerKitPro` is injected via the same protocols — the open-source layer has no knowledge of `PlayerKitPro`:

```swift
import PlayerKit
import PlayerKitNative
import PlayerKitPro  // closed-source

let backend = try NativeBackend(
    renderer: EDRRenderer(),           // PRO
    audioOutput: PassthroughOutput()  // PRO
)
let player = Player(backend: backend)
player.addFrameSink(DLNAFrameSink(target: device))  // PRO
```

## License

PlayerKit is licensed under **LGPL v2.1+**. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

PlayerKit links FFmpeg (LGPL v2.1+). Users may replace the FFmpeg xcframeworks to satisfy LGPL requirements — see [`NOTICE`](NOTICE) for instructions.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Signed commits (`git commit -s`) required.
