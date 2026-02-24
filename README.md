<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Textream icon">
</p>

<h1 align="center">Textream 中文增强版（非官方）</h1>

<p align="center">
  基于开源项目的中文增强版本，面向中文演讲/录制场景做了本地化与识别能力扩展。<br>
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
git clone <your-repo-url>
cd textream-src-zh/Textream
open Textream.xcodeproj
```

Xcode 中 `⌘R` 运行，或使用 `xcodebuild` 进行 Release 构建。

## 合规与归属

本仓库是衍生项目。请阅读 [NOTICE](./NOTICE)。

- 上游项目：`https://github.com/f/textream`
- 上游 README 在 **2026-02-24** 标注为 MIT
- 本仓库保留并尊重原项目署名与来源，不宣称替代原项目版权

