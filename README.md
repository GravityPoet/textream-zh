<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Textream icon">
</p>

<h1 align="center">Textream 中文增强版 </h1>

<p align="center">
  一款隐身于 Mac 摄像头下方的智能提词器：专为视频录制、直播与会议设计，帮您保持自然眼神交流。<br>
  支持苹果自带语音识别与无网本地 AI 大模型，能随着您的真实语速自动跟踪和滚动文案，彻底告别忘词与手动滑屏的烦恼。
</p>

<p align="center">
  <a href="README.en.md">English Version</a> · <a href="NOTICE">Attribution & Notice</a>
</p>

<p align="center">
  <img src="docs/video.gif" width="600" alt="Textream demo">
</p>

## 下载与安装

**[👉 前往 Releases 页面下载最新的 `.dmg` 安装包](https://github.com/GravityPoet/textream-zh/releases/latest)**

> 需运行 **macOS 15 Sequoia** 及以上系统。兼容 Apple Silicon (M系列) 以及 Intel 设备。

### 首次运行提示
由于本应用为开源衍生版本未进行开发者签名，macOS 首次运行通常会进行拦截。
建议您将下载好的应用拖入 `应用程序` 文件夹后，在「终端 (Terminal)」里执行下方命令来解除系统拦截：

```bash
xattr -cr /Applications/Textream.app
```

之后，在访达 (Finder) 里的「应用程序」上找到它，**右键点击并选择“打开”**即可。（此操作只需执行一次，之后就可以正常双击打开了。）

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

