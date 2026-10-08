# 锐途办公大师 1.2.0

面向 macOS 14 及以上的本地办公工具。本版先完善基础处理流程，没有接入 DeepSeek 或其他大模型服务。

## 直接使用

从 [GitHub Releases 下载 1.2.0 安装包](https://github.com/rylanwei-creator/ruitu-office-master/releases/tag/v1.2.0)。仓库保存源码，安装包单独放在 Releases 中。

打开 `release/锐途办公大师.app`。也可以解压 `release/锐途办公大师_1.2.0_macOS.zip`，将应用复制到“应用程序”文件夹后打开。成品包含 Apple Silicon（arm64）和 Intel（x86_64）两个架构。

图片、PDF、视频等转换完成后，点击“保存到…”导出。处理结果暂存于应用缓存，原文件保持原样；批量改名会直接改动原文件名，执行前请检查预览，可使用“撤销上次改名”。重复导出自动加编号，不覆盖目录中的已有文件。

这是本机生成的 ad-hoc 签名版本，未使用 Apple Developer ID 签名或 Apple 公证。公开分发前需要完成正式签名、公证和其他设备验收；无需为本机开发包关闭系统安全设置。

新增证件照工具：常用与自定义规格、本机人像换底、裁切构图、实际大小预览、JPG 大小上限，以及 6 寸/A4 打印排版 PDF。操作与边界详见 `docs/使用说明.md`。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/RuiTuOfficeMaster/Shared` | 数据模型、业务服务、状态管理和公共工具 |
| `Sources/RuiTuOfficeMaster/macOS` | macOS 界面、应用入口和图标资源 |
| `Tests` | 核心功能回归测试 |
| `scripts/build-app.sh` | 构建通用应用和 ZIP 成品 |
| `scripts/build-icon.sh` | 从圆角 AppIcon.png 生成 macOS 应用图标 |
| `scripts/test.sh` | 执行回归测试 |
| `docs` | 当前使用说明、验收记录、功能边界及开发历史 |
| `release` | 当前成品，仅保留最新版本 |

## 从源码构建

安装 Xcode 及其命令行工具，使用 Swift 6.1 或更新版本。项目没有第三方包依赖。

```sh
./scripts/test.sh
./scripts/build-app.sh
```

默认构建 arm64 + x86_64 通用版本。仅构建本机架构时运行：

```sh
RUITU_BUILD_CURRENT_ARCH_ONLY=1 ./scripts/build-app.sh
```

构建缓存放在 `.build`，可通过 `RUITU_BUILD_ROOT` 指定其他目录。受限制的构建环境若不支持 SwiftPM 的嵌套 sandbox，可设置 `RUITU_DISABLE_SWIFTPM_SANDBOX=1`；普通本机构建不需要设置。

详细操作见 `docs/使用说明.md`，验证范围见 `docs/验收记录.md`，适用范围见 `docs/功能边界.md`。
