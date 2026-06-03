# Whispr Input — 设计文档

> 中文语音输入到 Ghostty + Claude Code 的 macOS 原生工具
> 2026-06-03

---

## 1. 项目定位

一个极简的 macOS 菜单栏应用，按住反引号键说话，松手后语音转文字自动粘贴到 Ghostty 终端光标处。专注做一件事：**让中文开发者用语音在终端里敲命令**。

参考项目：[OpenWhispr](https://github.com/OpenWhispr/openwhispr)（MIT 协议），借鉴其 Push-to-talk 键盘监听、音频采集和浮动窗设计模式。

---

## 2. 技术栈

| 层 | 技术 | 理由 |
|---|---|---|
| UI 框架 | SwiftUI (macOS 15+) | 原生组件，菜单栏 App + 浮动窗零依赖 |
| 键盘监听 | CGEvent Tap (kCGHIDEventTap) | 全局热键拦截，支持 tap/hold 区分 |
| 音频采集 | AVAudioEngine | 系统原生，低延迟 PCM 采集 |
| 语音转文本 | OpenRouter Whisper API | 用户已有 API Key，中文识别准确率高 |
| 文本注入 | NSPasteboard + CGEvent 合成 Cmd+V | 简单可靠，不碰 Ghostty 内部 |
| API Key 存储 | macOS Keychain（SecItem API） | 系统级加密存储 |
| 打包分发 | .app bundle + DMG | 标准 macOS 分发方式 |

**不依赖项**：不引入 Electron、Node.js、Python runtime。纯 Swift，运行时不依赖任何外部进程。

---

## 3. 架构

### 3.1 进程模型

单进程 macOS 应用，包含 4 个核心服务类和一个 App 壳：

```
┌──────────────────────────────────────────────┐
│                  App Entry                    │
│   SwiftUI @main → AppDelegate                 │
│   菜单栏图标 · 设置窗口 · 权限引导             │
├──────────────────────────────────────────────┤
│                                              │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │ KeyboardMon  │  │  AudioCaptureService │  │
│  │              │  │                      │  │
│  │ CGEvent Tap  │  │  AVAudioEngine       │  │
│  │ tap/hold 区分│──│  PCM → WAV (内存)    │──│
│  │ 200ms 阈值   │  │  实时 RMS 音量       │  │
│  └──────────────┘  └──────────────────────┘  │
│                                    │         │
│                                    ▼         │
│                        ┌──────────────────┐  │
│                        │   STTService     │  │
│                        │                  │  │
│                        │ OpenRouter API   │  │
│                        │ Whisper V3 Turbo │  │
│                        │ 中文 + 错误处理   │  │
│                        └────────┬─────────┘  │
│                                 │            │
│                                 ▼            │
│                        ┌──────────────────┐  │
│                        │  PasteService    │  │
│                        │                  │  │
│                        │ NSPasteboard     │  │
│                        │ + CGEvent Cmd+V  │  │
│                        └──────────────────┘  │
│                                              │
│  ┌──────────────────────────────────────────┐│
│  │            OverlayWindow                 ││
│  │  毛玻璃浮动窗 · 实时波形 · 转录预览        ││
│  └──────────────────────────────────────────┘│
│                                              │
│  ┌──────────────────────────────────────────┐│
│  │           SettingsWindow                  ││
│  │  API Key · 模型选择 · 语言 · 快捷键       ││
│  └──────────────────────────────────────────┘│
└──────────────────────────────────────────────┘
```

### 3.2 数据流

```
用户按住反引号
  → CGEvent Tap 拦截 keyDown(keyCode=50), 启动 200ms Timer
  → Timer 到期 → KeyboardMon 通知 AudioCaptureService.start()
  → AVAudioEngine mic tap 采集 PCM, 推送 RMS 音量 → OverlayWindow
  → 用户松手
  → CGEvent Tap 拦截 keyUp → AudioCaptureService.stop()
  → PCM Buffer 内存中编码为 WAV（16kHz, mono, 16-bit）
  → STTService.transcribe(wavData) → POST OpenRouter API
  → 解析 response["text"]
  → PasteService.paste(text) → NSPasteboard.setString + CGEvent Cmd+V
  → 文本出现在 Ghostty 光标位置
```

### 3.3 Tap/Hold 区分逻辑

```
keyDown(keyCode=50, 反引号)
  ├─ 启动 200ms Timer
  │
  ├─ 情况 A: keyUp 在 200ms 内到达
  │   → 取消 Timer → 放行 keyDown + keyUp 给系统
  │   → 正常打出反引号字符（零影响正常打字）
  │
  └─ 情况 B: 200ms Timer 先到期，keyUp 尚未到达
      → 判定为 hold → 开始录音
      → 吞掉后续 keyUp 事件（系统看不到这次按键）
```

---

## 4. 服务设计

### 4.1 KeyboardMonitor

- **职责**：全局键盘监听，区分反引号的 tap/hold 操作
- **权限**：需要辅助功能权限（Accessibility），安装 CGEvent Tap
- **tap 阈值**：200ms（参考 OpenWhispr 实践）
- **状态机**：
  - `idle` → backtick keyDown → `pending`（200ms 计时）
  - `pending` → keyUp 在 200ms 内 → `idle`（放行，正常字符）
  - `pending` → 200ms 超时 → `recording`（开始录音）
  - `recording` → keyUp → `idle`（停止录音，触发转写+粘贴）
- **异常**：`recording` 状态下按其他键不作反应；`pending` 状态忽略非反引号事件

### 4.2 AudioCaptureService

- **职责**：麦克风采集，输出 WAV buffer
- **音频格式**：16kHz 采样率，单声道，16-bit PCM
- **编码**：内存中完成 PCM → WAV，不写磁盘
- **音量推送**：每 50ms 计算 RMS 值，通过 Combine publisher 推送给 OverlayWindow
- **权限**：需要麦克风权限（系统弹窗）
- **单次最长录音**：30 秒（OpenRouter 建议上限，防止误触无限录音）

### 4.3 STTService

- **API 端点**：`POST https://openrouter.ai/api/v1/audio/transcriptions`
- **请求格式**：
  ```json
  {
    "model": "openai/whisper-large-v3-turbo",
    "input_audio": {
      "data": "<base64-encoded-wav>",
      "format": "wav"
    },
    "language": "zh"
  }
  ```
- **响应格式**：`{ "text": "转写文本..." }`
- **错误处理**：
  - 网络超时（5s）→ 静默失败，菜单栏图标短暂闪烁红色
  - 401（Key 无效）→ 菜单栏图标持续黄色，提醒用户检查设置
  - 429（限流）→ 延迟 2s 重试一次
  - 其他错误 → 静默失败，不打断用户
- **API Key**：从 Keychain 读取，不存在时引导用户打开设置

### 4.4 PasteService

- **职责**：将转写文本粘贴到前台应用
- **步骤**：
  1. `NSPasteboard.general.clearContents()`
  2. `NSPasteboard.general.setString(text, forType: .string)`
  3. 合成 `Cmd+V` 键盘事件（kCGEventKeyDown + kVK_ANSI_V + cmd mask）
  4. `CGEvent.post(.cgsessionTap, ...)`
- **不恢复剪贴板**：语音输入窗口通常几秒到十几秒，使用场景不涉及剪贴板并发

### 4.5 OverlayWindow

- **视觉风格**：毛玻璃材质 (backdrop-filter: blur(40px))，20px 连续曲率圆角，双层阴影
- **内容**：
  - 极简条形，约 400px 宽，16px 内边距
  - 上部：音频波形（RMS 实时映射到条状高度）
  - 中部：实时转写文本（不支持流式 API 则松手后短暂显示 loading 状态）
  - 下部：红点 + 「按住 ` 录音」提示
- **出现动画**：spring 弹性缩放（0.3s，damping 0.7）
- **消失动画**：淡出缩放（0.2s）
- **定位**：屏幕顶部居中（NSScreen.main.frame，Y 偏移状态栏下方）
- **鼠标穿透**：窗口不拦截点击，鼠标可以穿过浮动窗操作背后的终端
- **窗口层级**：浮动在所有窗口之上（NSWindow.Level.floating）

### 4.6 SettingsWindow

- **样式**：Settings 场景（macOS 14+），标准 macOS 偏好面板
- **Tab 分组**：
  1. **API**：OpenRouter API Key（安全输入框，Keychain 存储）、模型选择（下拉）、识别语言（下拉）
  2. **快捷键**：触发键显示 + 修改按钮（点按进入捕获模式）、长按阈值滑块（150-500ms）
  3. **通用**：开机启动开关、松手提示音开关、错误通知开关
- **API Key**：输入后即时写入 Keychain，退出设置页面后不可见

---

## 5. 错误状态处理

| 状态 | 表现 | 恢复 |
|------|------|------|
| 无麦克风权限 | 菜单栏图标灰色 | 点击图标 → 请求权限 |
| 无辅助功能权限 | 菜单栏图标橙色 | 点击图标 → 打开系统设置 |
| API Key 未设置 | 菜单栏图标黄色 | 点击图标 → 打开设置 |
| API Key 无效 (401) | 图标短暂黄色闪烁 | 检查设置页 Key |
| 转写网络超时 | 静默失败，无粘贴 | 无操作，下次正常 |
| 转写返回空文本 | 静默失败 | 无操作 |
| CGEvent Tap 被中断 | 自动重新注册（最多 3 次） | 3 次失败后图标变红，需手动重启 |
| 录音中失去前台焦点 | 继续录音，正常完成 | — |

---

## 6. 菜单栏图标设计

```
常态：🎤 图标（SF Symbol: "mic.fill"）
录音中：绿色呼吸灯替代图标
转写中：蓝色旋转指示器
错误：黄色/红色静态图标
```

图标使用 macOS 系统 SF Symbol，跟系统外观自动适配亮/暗模式。

---

## 7. 权限要求

| 权限 | 用途 | 引导方式 |
|------|------|----------|
| Accessibility | CGEvent Tap 全局键盘监听 | 首次启动弹窗 → 打开系统设置 → 隐私与安全性 → 辅助功能 |
| Microphone | 录音 | 首次录音时系统自动弹窗 |

---

## 8. 项目结构

```
whispr-input/
├── WhisprInput.xcodeproj
├── WhisprInput/
│   ├── WhisprInputApp.swift          # @main 入口
│   ├── AppDelegate.swift              # NSApplicationDelegate，菜单栏生命周期
│   ├── Services/
│   │   ├── KeyboardMonitor.swift      # CGEvent Tap 键盘监听
│   │   ├── AudioCaptureService.swift  # AVAudioEngine 音频采集
│   │   ├── STTService.swift           # OpenRouter API 调用
│   │   └── PasteService.swift         # 剪贴板 + Cmd+V
│   ├── UI/
│   │   ├── MenuBarView.swift          # 菜单栏图标及下拉菜单
│   │   ├── OverlayWindow.swift        # 浮动录音窗
│   │   └── SettingsView.swift         # 设置窗口
│   ├── Models/
│   │   └── AppState.swift             # 应用状态模型
│   └── Resources/
│       └── Assets.xcassets            # 图标资源
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-06-03-whispr-input-design.md
└── README.md
```

---

## 9. 非目标（v1.0 不做）

- ❌ 离线本地模型（v1 只做云端 API）
- ❌ 会议转录、笔记系统、AI Agent（参考 OpenWhispr 的其他功能）
- ❌ Windows/Linux 支持（架构预留扩展点，但不实现）
- ❌ 流式转写（OpenRouter Whisper API 返回完整结果后才粘贴）
- ❌ 多语言 UI（界面仅中文/英文，识别语言支持中文为主）
- ❌ 历史记录（不保存音频和转写文本）
