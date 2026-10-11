# 锐途办公大师 1.5.4

面向 macOS 14 及以上的本地办公工具。本版先完善基础处理流程，没有接入 DeepSeek 或其他大模型服务。

[访问官网](https://rylanwei-creator.github.io/ruitu-office-master/) · [最新版发布页](https://github.com/rylanwei-creator/ruitu-office-master/releases/latest)

## 直接使用

从 [GitHub 下载 1.5.4 安装包](https://github.com/rylanwei-creator/ruitu-office-master/releases/download/v1.5.4/RuituOfficeMaster_1.5.4_macOS.zip)，解压后将应用复制到“应用程序”文件夹后打开。成品包含 Apple Silicon（arm64）和 Intel（x86_64）两个架构。

图片、PDF、视频等转换完成后，点击“保存到…”导出。处理结果暂存于应用缓存，原文件保持原样；批量改名会直接改动原文件名，执行前请检查预览，可使用“撤销上次改名”。重复导出自动加编号，不覆盖目录中的已有文件。

这是本机生成的 ad-hoc 签名版本，未使用 Apple Developer ID 签名或 Apple 公证。尚未完成其他设备的全面验收；请保留系统安全设置，按 macOS 提示检查应用来源。

本版新增图片批处理任务中心、后台文件夹导入、取消/重试、首页搜索与收藏，并加强改名预览及撤销校验。此前的证件照功能保留：常用与自定义规格、本机人像换底、裁切构图、实际大小预览、JPG 大小上限，以及 6 寸/A4 打印排版 PDF。操作与边界详见 `docs/使用说明.md`。

本版 OCR 多张图片识别结果按图片分卡显示，保留完整文件名，可单独编辑、复制、保存 TXT；复制和导出全部会保留来源标识，译文显示在对应图片卡片中。

本版进一步增加 OCR 原图缩略图与放大对照预览、自适应文字区域和展开阅读；批量 TXT 可选择合并导出，或为每张有文字的图片生成独立 TXT。同名文件自动编号，保留已有文件。

本版完善 PDF 批量处理：逐文件或拆分范围显示状态，支持停止、单项重试和重试未完成项；成功结果保留。合并需所有源文件有效，出错后整组重试，避免漏页漏文件。

本版修复改名后结果提示消失：操作结果独立显示，保留原名与新名、成功/跳过数量和撤销入口；清空待处理列表不会丢失上次结果。

本版为 PDF 拆分增加总页数、翻页与放大预览、页码跳转和范围校验提示。点击输出范围可预览其第一页；当前页是否在范围内、预计生成文件数及输出页数均可查看。

保留抠图与图片去水印：抠图导出透明 PNG，可框选清除残留背景；图片提供周边插值和取样修补，不承诺恢复水印遮住的原始细节。1.4.1 已移除视频去水印，原有视频压缩和音视频转换仍可使用。

本版新增“文件整理”：按扩展名分为七类，支持多个源文件夹、递归与排除目录。默认复制，先显示原路径、目标路径和同名编号，再点击执行；也可选择移动并再次确认。结果逐文件显示，本机保存整理日志，重启后可查看和尝试撤销。撤销前校验身份及内容，文件已变化或原位置被占用时保留文件并说明原因。

文件整理预览与完成后的结果按目标目录分组显示：整理位置 → 分类文件夹 → 文件。每类显示文件数，支持展开/收起，文件保留来源、编号后名称及实际处理状态；右键可复制来源或目标路径。

证件照打印新增整页排版预览和放大查看：选择纸张、照片规格或裁切标记后自动更新；保存的 PDF 与预览使用同一份排版。

## 更新测试图
<img width="2240" height="1520" alt="28d41e52c6eb4fcb247a517388416cd0" src="https://github.com/user-attachments/assets/784ebf8e-6e70-4ae2-af79-d0580ec8d184" />
<img width="2238" height="1520" alt="8d5888314cbd1c89bb48075bcdb7a258" src="https://github.com/user-attachments/assets/f84326df-a501-4680-b6e3-34f93ba94a5a" />



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
| GitHub Releases | 各公开版本的安装包与校验文件 |

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

文件整理结果提供“删除这条记录”，清理当前选中的本机日志，保留原文件和整理后的文件；该记录的撤销入口同时移除。

侧栏底部和设置 → 关于均提供“检查更新”，联网查询 GitHub 正式发布版并比较版本；显示发现新版本、已是最新正式发布版或当前版本较新。关于页增加“访问官网”，保留发布说明与下载入口。不自动安装更新。

## 更新测试图
<img width="2240" height="1520" alt="28d41e52c6eb4fcb247a517388416cd0" src="https://github.com/user-attachments/assets/784ebf8e-6e70-4ae2-af79-d0580ec8d184" />
<img width="2238" height="1520" alt="8d5888314cbd1c89bb48075bcdb7a258" src="https://github.com/user-attachments/assets/f84326df-a501-4680-b6e3-34f93ba94a5a" />



## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/RuiTuOfficeMaster/Shared` | 数据模型、业务服务、状态管理和公共工具 |
| `Sources/RuiTuOfficeMaster/macOS` | macOS 界面、应用入口和图标资源 |
| `Tests` | 核心功能回归测试 |
| `scripts/build-app.sh` | 构建通用应用和 ZIP 成品 |
| `scripts/test.sh` | 执行回归测试 |
| `docs` | 当前使用说明、验收记录、功能边界及开发历史 |
| `release` | 当前成品，仅保留最新版本 |
| `backups` | 优化前源码与成品备份、校验清单及恢复说明 |

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
