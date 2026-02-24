<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Textream icon">
</p>

<h1 align="center">Textream 中文增强版 </h1>

<p align="center">
  一款隐身在 Mac 摄像头下的智能提词器：由于接入了您本地运行的模型，所以它能在不上传语音数据的情况下，随着您真实讲话的进度自动跟踪和往下滚动文案。
</p>

<p align="center">
  <a href="README.en.md">English Version</a> · <a href="NOTICE">Attribution & Notice</a>
</p>

<p align="center">
  <img src="docs/video.gif" width="600" alt="Textream demo">
</p>

## 主要改动

- 全量界面汉化（设置、提示、引导等主要页面）
- 新增本地语音模型导入入口（可配置本地识别程序与模型文件）
- 支持本地语音大模型流式识别接入
- 增强中文文案跟读匹配稳定性（重复段落防误跳、远跳抑制）
- 修复设置页滚动等可用性问题

## 适用场景

- 中文提词演讲、直播口播、录屏讲解
- 不希望语音数据上传云端，优先本地识别
- 需要在重复文案中尽量避免“跨段乱跳”

## 本地模型说明

在 `设置 -> 引导 -> 本地模型` 中：

1. 导入识别程序（如支持流式的人工智能语音服务程序）
2. 导入模型文件（`.gguf`）
3. 选择语言（如 `中文（普通话）`）
4. 切换到 `本地模型` 识别模式

## 构建

```bash
git clone https://github.com/GravityPoet/textream-zh.git
cd textream-zh/Textream
open Textream.xcodeproj
```

Xcode 中 `⌘R` 运行，或使用 `xcodebuild` 进行 Release 构建。

## 合规与归属

本仓库是衍生项目。请阅读 [NOTICE](./NOTICE)。

