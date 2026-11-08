# 锐途办公大师 1.9.0

macOS 文件工作台与 Rito AI 办公助手。

[官网](https://rylanwei-creator.github.io/ruitu-office-master/) · [下载](https://github.com/rylanwei-creator/ruitu-office-master/releases/latest)

## 使用

支持 macOS 14 及以上的 Apple Silicon Mac。解压下载的 ZIP，将应用放入「应用程序」后打开。

普通工具包含文件改名、文件整理、图片处理、智能抠图、图片去水印、证件照、拼图、PDF、格式转换、视频压缩、音视频转换与 OCR。

切换至 Rito AI，可使用自然语言描述任务，核对参数和预览后确认处理。首次使用本地模式需下载模型，下载完成后可离线聊天；云端模式需在 AI 设置填写自己的接口与密钥，费用和额度由所选服务商决定。API Key 保存在 macOS Keychain 中。

文件处理由本机服务执行，云端聊天只发送文字与有限上下文，不发送附件内容。普通工具无需模型或 API Key。模型权重单独下载，不包含在安装包内。

## 新增功能

- 新增 Rito AI 办公模式，支持本地 Qwen 模型和自定义云端 API。
- 新增 Rito 动态像素精灵、聊天历史、附件续接和任务结果卡片。
- 新增 24 项本机工具调用及多步骤任务计划，支持参数设置、执行预览和确认处理。
- 新增图片拼图、横向与纵向长图拼接，支持布局、滤镜、文字和 PNG/JPG 导出。
- 新增图片目标体积压缩，支持轻度、均衡、强力和自定义体积范围。
- 新增 AI 任务参数核对、附件排序、原图预览、全文复制和结果文件打开与复制。

## 从源码构建

安装 Xcode 16 或更新版本，运行：

```sh
./scripts/test.sh
./scripts/build-app.sh
```

程序在 release 目录生成，构建仅包含 arm64。第三方组件说明见 THIRD_PARTY_NOTICES。

## 安装说明

应用使用 ad-hoc 签名，未经过 Apple Developer ID 公证。下载后请核对 GitHub 发布来源，不要关闭系统安全设置。
