# Happy Whispr

Happy Whispr 是一个原生 macOS 菜单栏语音输入工具。按住反引号键 `` ` `` 说话，松开后自动转写成文字，并粘贴到当前光标位置。

这个项目最初是为了让中文开发者在 Ghostty、Claude Code、终端和其他文本输入场景里更自然地使用语音输入。它保持小而直接：纯 Swift、菜单栏常驻、无 Electron、无后台脚本运行时。

## 功能特性

- 按住 `` ` `` 开始录音，松开后转写并粘贴。
- 短按 `` ` `` 仍然会输入正常的反引号字符。
- 使用 OpenRouter Whisper 音频转写接口。
- API Key 存储在 macOS Keychain。
- 使用 macOS 原生 `CGEventTap` 监听全局按键。
- 使用 `AVAudioEngine` 采集麦克风音频。
- 使用 `NSPasteboard` 和合成 `Cmd+V` 完成文本注入。
- 菜单栏状态图标会根据录音、转写和错误状态变色。
- 录音浮窗显示与应用图标一致的绿色声波反馈。
- 纯 Swift Package 项目，方便直接构建和二次开发。

## 运行要求

- macOS 14 或更高版本
- Swift 5.9 或更高版本
- OpenRouter API Key
- 麦克风权限
- 辅助功能权限

辅助功能权限用于全局按键监听和粘贴事件。麦克风权限用于录音采集。

## 快速开始

克隆仓库后进入项目目录：

```bash
git clone https://github.com/pmy0721/happy-whispr.git
cd happy-whispr
```

构建 Swift Package：

```bash
swift build
```

打包成本地 `.app`：

```bash
Scripts/build-app.sh
```

打包产物会生成在：

```text
.build/Happy Whispr.app
```

启动应用：

```bash
open ".build/Happy Whispr.app"
```

如果你希望日常从 `/Applications` 启动，可以复制过去：

```bash
ditto ".build/Happy Whispr.app" "/Applications/Happy Whispr.app"
open "/Applications/Happy Whispr.app"
```

## 首次配置

启动后，点击菜单栏里的 Happy Whispr 图标，打开 Settings。

1. 在 API 页面输入 OpenRouter API Key，然后点击 `Save API Key`。
2. 在 General 页面检查麦克风权限。
3. 在 General 页面检查辅助功能权限。
4. 如果辅助功能未授权，点击 `Open Settings...`，在系统设置里允许 `Happy Whispr`。
5. 授权后回到设置页，点击 `Refresh`。

OpenRouter API Key 可以在这里创建：

```text
https://openrouter.ai/keys
```

## 使用方式

1. 把光标放在你想输入文字的位置。
2. 按住反引号键 `` ` ``。
3. 开始说话。
4. 松开 `` ` ``。
5. Happy Whispr 会转写语音，并把文字粘贴到当前应用。

短按 `` ` `` 不会触发录音，会像普通键盘输入一样打出反引号。

## 设置说明

### API

- `API Key`：OpenRouter API Key，保存到 macOS Keychain。
- `Model`：当前支持 Whisper V3 Turbo 和 Whisper V3。
- `Language`：支持中文、英文、日文和自动识别。

### Shortcuts

- `Trigger Key`：当前固定为反引号键。
- `Hold Threshold`：按住多久后判定为录音，默认 200ms。

### General

- `Microphone`：麦克风权限状态。
- `Accessibility`：辅助功能权限状态。
- `Launch at login`、`Play sound on paste`、`Show error notifications` 当前仍是后续功能，界面中暂时禁用。

## 架构概览

```text
用户按住 `
  -> KeyboardMonitor 识别 tap / hold
  -> AppState 切换到 recording
  -> AudioCaptureService 采集音频并编码 WAV
  -> STTService 调用 OpenRouter Whisper
  -> PasteService 写入剪贴板并触发 Cmd+V
```

核心模块：

```text
Sources/HappyWhispr/
  App/
    HappyWhisprApp.swift          应用入口、菜单栏生命周期
  Models/
    AppState.swift                应用状态、设置持久化、服务协调
  Services/
    KeyboardMonitor.swift         全局按键监听和 tap/hold 判断
    AudioCaptureService.swift     麦克风采集、RMS 音量、WAV 编码
    STTService.swift              Keychain 和 OpenRouter 转写请求
    PasteService.swift            剪贴板写入和 Cmd+V 粘贴
  UI/
    MenuBarView.swift             菜单栏菜单和状态图标
    OverlayWindow.swift           录音浮窗和声波反馈
    SettingsView.swift            设置窗口
Resources/
  Info.plist                      app bundle 元数据
  AppIcon.icns                    app 图标
Scripts/
  build-app.sh                    本地打包脚本
```

## 安全与隐私

- API Key 只存储在 macOS Keychain。
- 应用不会把 API Key 写入配置文件、日志或 UserDefaults。
- 音频在内存中编码为 WAV，不写入磁盘。
- 转写请求会发送到 OpenRouter 的音频转写接口。
- 粘贴使用系统剪贴板，应用不会恢复旧剪贴板内容。

## 常见问题

### 设置页显示辅助功能未授权

如果你已经在系统设置里授权，但 Happy Whispr 仍显示未授权：

1. 确认正在运行的是 `/Applications/Happy Whispr.app`。
2. 打开系统设置 -> 隐私与安全性 -> 辅助功能。
3. 删除旧的 `Happy Whispr` 条目。
4. 重新添加 `/Applications/Happy Whispr.app`。
5. 重启 Happy Whispr。
6. 回到设置页点击 `Refresh`。

在开发过程中频繁重新打包时，macOS TCC 有时会把旧 app 和新 app 当成不同条目。

### 点击菜单栏图标时弹出钥匙串密码

新版只在真正转写时读取 Keychain 中的 API Key。菜单状态检查只查询是否存在 Key，不会读取密钥内容。如果你仍遇到钥匙串弹窗，建议删除旧 app、重新安装新版，并重新保存 API Key。

### 按住反引号没有开始录音

检查：

- 辅助功能权限是否已授权。
- 麦克风权限是否已授权。
- 是否按住超过 `Hold Threshold`。
- 当前键盘布局是否对应 ANSI 反引号键。

### 转写后没有粘贴

检查：

- API Key 是否已保存。
- OpenRouter 账号是否可用。
- 当前应用是否允许粘贴。
- 当前光标是否在可输入区域。

## 当前限制

- 触发键目前固定为 ANSI 反引号。
- API Key 需要手动配置。
- 录音最长 30 秒。
- 当前没有发布 DMG，只提供本地构建脚本。
- Clipboard 粘贴后不会恢复旧剪贴板内容。
- 启动项、提示音、错误通知等开关暂未实现。

## 开发

常用命令：

```bash
swift build
Scripts/build-app.sh
open ".build/Happy Whispr.app"
```

查看当前 app 签名：

```bash
codesign --verify --deep --strict --verbose=2 ".build/Happy Whispr.app"
```

覆盖安装到 `/Applications`：

```bash
pkill -f "/Happy Whispr.app/Contents/MacOS/HappyWhispr" || true
ditto ".build/Happy Whispr.app" "/Applications/Happy Whispr.app"
open "/Applications/Happy Whispr.app"
```

## 许可证

当前仓库暂未添加开源许可证。未经许可，请不要将代码用于再分发场景。
