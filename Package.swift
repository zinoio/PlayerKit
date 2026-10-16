// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
        .library(name: "PlayerKitNative", targets: ["PlayerKitNative"]),
    ],
    targets: [
        .target(
            name: "PlayerKit",
            dependencies: [],
            path: "Sources/PlayerKit",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // CFFmpeg: NativeBackend's FFmpeg wrapper.
        // xcframeworks are built by scripts/build_ffmpeg.sh → Sources/CFFmpeg/xcframeworks/
        // Run the script once after cloning, and again to upgrade FFmpeg.
        .target(
            name: "CFFmpeg",
            dependencies: ["FFAvformat", "FFAvcodec", "FFAvutil", "FFSwresample", "FFSwscale"],
            path: "Sources/CFFmpeg",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        // CAss: NativeBackend's libass ASS/SSA subtitle renderer wrapper.
        // xcframeworks are built by scripts/build_libass.sh → Sources/CAss/xcframeworks/
        // (freetype + fribidi + libass; CoreText font provider, no fontconfig/harfbuzz).
        .target(
            name: "CAss",
            dependencies: ["AssLibass", "AssFreetype", "AssFribidi", "AssHarfbuzz"],
            path: "Sources/CAss",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "PlayerKitNative",
            dependencies: ["PlayerKit", "CFFmpeg", "CAss"],
            path: "Sources/PlayerKitNative",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "PlayerKitNative", "CFFmpeg"],
            path: "Tests/PlayerKitTests",
            resources: [.copy("Fixtures")]
        ),

        // NativeBackend FFmpeg — built from source by scripts/build_ffmpeg.sh.
        // xcframeworks are committed to the refluxio/PlayerKit independent repo;
        // in the reflux monorepo they are git-ignored — run the script after cloning.
        .binaryTarget(name: "FFAvcodec",    path: "Sources/CFFmpeg/xcframeworks/libavcodec.xcframework"),
        .binaryTarget(name: "FFAvformat",   path: "Sources/CFFmpeg/xcframeworks/libavformat.xcframework"),
        .binaryTarget(name: "FFAvutil",     path: "Sources/CFFmpeg/xcframeworks/libavutil.xcframework"),
        .binaryTarget(name: "FFSwresample", path: "Sources/CFFmpeg/xcframeworks/libswresample.xcframework"),
        .binaryTarget(name: "FFSwscale",    path: "Sources/CFFmpeg/xcframeworks/libswscale.xcframework"),

        // libass + deps — built from source by scripts/build_libass.sh, same
        // committed-xcframework model as CFFmpeg above.
        .binaryTarget(name: "AssLibass",   path: "Sources/CAss/xcframeworks/libass.xcframework"),
        .binaryTarget(name: "AssFreetype", path: "Sources/CAss/xcframeworks/libfreetype.xcframework"),
        .binaryTarget(name: "AssFribidi",  path: "Sources/CAss/xcframeworks/libfribidi.xcframework"),
        .binaryTarget(name: "AssHarfbuzz", path: "Sources/CAss/xcframeworks/libharfbuzz.xcframework"),

    ]
)
