// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingRecorderCore", targets: ["MeetingRecorderCore"]),
        .executable(name: "MeetingRecorderApp", targets: ["MeetingRecorderApp"]),
        .executable(name: "RecorderProbe", targets: ["RecorderProbe"]),
    ],
    targets: [
        .target(name: "MeetingRecorderCore"),
        .executableTarget(name: "MeetingRecorderApp", dependencies: ["MeetingRecorderCore"]),
        .executableTarget(name: "RecorderProbe", dependencies: ["MeetingRecorderCore"]),
        .testTarget(
            name: "MeetingRecorderCoreTests",
            dependencies: ["MeetingRecorderCore"],
            path: "Tests",
            exclude: ["MeetingRecorderAppTests"],
            sources: ["MeetingRecorderCoreTests", "TestSupport"]
        ),
        .testTarget(
            name: "MeetingRecorderAppTests",
            dependencies: ["MeetingRecorderApp", "MeetingRecorderCore"],
            path: "Tests/MeetingRecorderAppTests"
        ),
    ]
)
