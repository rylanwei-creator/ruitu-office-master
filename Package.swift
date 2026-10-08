// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuiTuOfficeMaster",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "RuiTuOfficeMaster",
            targets: ["RuiTuOfficeMaster"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RuiTuOfficeMaster",
            path: "Sources",
            resources: [
                .process("RuiTuOfficeMaster/macOS/Resources")
            ]
        ),
        .testTarget(name: "RuiTuOfficeMasterTests", dependencies: ["RuiTuOfficeMaster"])
    ]
)
