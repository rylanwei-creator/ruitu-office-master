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
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.0"),
    ],
    targets: [
        .executableTarget(name: "RitoMLXValidation", dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
        ], path: "Validation/MLXProbe"),
        .executableTarget(
            name: "RuiTuOfficeMaster",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources",
            resources: [
                .process("RuiTuOfficeMaster/macOS/Resources")
            ]
        ),
        .testTarget(name: "RuiTuOfficeMasterTests", dependencies: ["RuiTuOfficeMaster"])
    ]
)
