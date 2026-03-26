# TypeFlow 技术设计文档

## 1. 项目概述

macOS 菜单栏常驻语音输入工具。按住快捷键说话 → 松开 → ASR 转写（本地或云端） → 云端润色 → 智能填入。

- **目标用户**: 个人使用
- **最低系统**: macOS 14.0+
- **开发语言**: Swift / SwiftUI
- **App 形态**: 菜单栏 app（LSUIElement），无主窗口

## 2. 核心流程

```
┌─────────┐    ┌───────────┐    ┌────────────┐    ┌──────────┐    ┌──────────┐
│ 按住快捷键 │───→│  录音采集   │───→│ ASR 引擎    │───→│ LLM 润色  │───→│  文本输出  │
│ (按下)    │    │ AVAudioEngine│   │ (可切换)    │    │ 云端 API  │    │          │
└─────────┘    └───────────┘    └────────────┘    └──────────┘    └──────────┘
     │                                                               │  │  │
     │              松开快捷键触发后续流程                                │  │  │
     │                                                               │  │  │
     │   录音期间: 桌面浮动录音指示器（最高层级，呼吸动画）                  │  │  │
     │                                                               │  │  │
     │                              ┌── 输入框 + 有选中 → 替换选中内容 ─┘  │  │
     │                              ├── 输入框 + 无选中 → 直接插入文本 ────┘  │
     │                              └── 非输入框 → 弹窗展示 + 复制按钮 ──────┘
```

**输出策略（三种情况）**:
1. **光标在输入框 + 有选中文本** → 替换选中内容
2. **光标在输入框 + 无选中文本** → 在光标位置直接插入
3. **光标不在输入框** → 弹窗展示润色结果，提供复制到剪贴板按钮

**浮动指示器（全流程可见）**:
- 桌面显示一个小型浮动图标（NSPanel, `level = .floating`），悬浮于普通窗口之上
- **录音中**: 麦克风图标 + 音浪扩散呼吸动画
- **处理中**: 松开快捷键后切换为加载动画（转写 + 润色期间），提示正在处理
- **完成**: 处理结束、文本输出后消失
- **错误**: 显示错误提示，2 秒后自动消失

### 状态机

```
         按住快捷键          松开快捷键         输出完成
  Idle ──────────→ Recording ──────────→ Processing ──────────→ Idle
                                              │
                                              │ 任一阶段失败
                                              ↓
                                            Error ──(2秒)──→ Idle
```

| 边界情况 | 处理规则 |
|----------|----------|
| Recording 中再按快捷键 | 忽略 |
| Processing 中按快捷键 | 忽略，等当前流程完成 |
| 录音时长 < 0.5 秒 | 视为误触，丢弃录音，直接回到 Idle |
| 录音时长超过上限 | 自动停止录音，进入 Processing。上限因引擎而异：本地 300s / 云端 180s |

### 异常处理

| 阶段 | 失败场景 | 处理 |
|------|----------|------|
| STT | 转写失败或返回空文本 | 指示器显示错误提示，2 秒后消失 |
| LLM | 超时/网络错误 | **降级输出转写原文**（跳过润色，仍然有用） |
| 文本输出 | AX 写入失败 | 回退到弹窗展示 |
| 权限 | 辅助功能/麦克风未授权 | 弹窗引导用户开启，功能不可用 |

## 3. 模块设计

### 3.1 HotkeyManager — 全局快捷键

**职责**: 监听按住/松开事件，驱动录音启停。

**实现方案**: `CGEvent.tapCreate` 创建事件监听。

- **修饰键**（默认 Left Option）：监听 `flagsChanged` 事件，通过 `CGEventFlags` 检测按下/释放
- **普通键**（用户自定义时）：监听 `keyDown` / `keyUp` 事件，过滤 keyDown 重复（macOS 按住会持续发 keyDown）
- 快捷键可配置，默认 `Left Option`（keycode 58）
- 仅在**单独按住**时触发，若同时按下其他键（如 Option+A 输入特殊字符）则不触发
  - 实现：按下时记录标记，若期间检测到其他键事件则取消本次触发
- 需要 **辅助功能权限**（Accessibility）

**关键接口**:
```swift
protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyDidPress()    // 按下 → 开始录音
    func hotkeyDidRelease()  // 松开 → 停止录音，启动转写
}
```

### 3.2 AudioRecorder — 录音采集

**职责**: 采集麦克风音频，输出 ASR 引擎所需格式。

**实现方案**: `AVAudioEngine` + `inputNode`。

- 输出格式: **16kHz, mono, Float32 PCM**（各 ASR 引擎通用输入格式）
- 硬件采样率通常非 16kHz，通过 `AVAudioConverter` 或 tap 的 format 参数进行重采样
- 使用 `installTap` 实时采集，缓存到内存 buffer
- 录音结束后返回完整 `[Float]` 数组
- **最短时长**: < 0.5 秒视为误触，丢弃（由状态机控制）
- **最长时长**: 由 `ConfigManager.maxRecordingDuration` 动态决定（本地 300s / 云端 180s），超时自动停止
- 需要 **麦克风权限**

**关键接口**:
```swift
class AudioRecorder {
    func startRecording() throws
    func stopRecording() -> [Float]  // 返回 PCM samples
}
```

### 3.3 SpeechEngine — 语音转写（可切换引擎）

**职责**: 将音频转为文字。通过 `SpeechEngine` protocol 抽象，支持多种 ASR 引擎切换。

**关键接口**:
```swift
protocol SpeechEngine: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func shutdown() async
}
```

- `Sendable` 而非 `Actor` — WhisperEngine 是独立 actor，QwenCloudEngine 也是独立 actor，两者都自动满足 Sendable
- 不含 `engineType` 属性，类型信息由 ConfigManager 管理
- 不定义统一错误类型，各引擎保留自己的 Error

**当前支持的引擎**:

| 引擎 | 类型 | 隔离方式 | 说明 |
|------|------|----------|------|
| WhisperEngine | 本地 | 独立 actor | whisper.cpp + GGML 模型，懒加载，空闲 5 分钟释放 |
| QwenCloudEngine | 云端 | 独立 actor | 百炼 qwen3-asr-flash，PCM16 WAV + base64 上传，30s 超时 |
| QwenLocalEngine | 本地 | — | Qwen3-ASR 本地推理（规划中） |

**通用行为**:
- 本地引擎：懒加载模型，空闲 5 分钟自动释放内存
- 云端引擎：无状态，每次转写独立请求；配置值（endpoint/model/apiKey）在 init 时快照传入
- 所有引擎使用独立 actor 隔离，CPU 密集操作不阻塞 MainActor

**引擎管理（AppDelegate）**:
- `speechEngine: (any SpeechEngine)?` — 通过 `createSpeechEngine()` 工厂方法按 `ConfigManager.speechEngineType` 创建
- 切换语义为"只影响下一次录音"：立即创建新引擎，旧引擎等 `processingTask` 完成后再 `shutdown()`
- Settings UI 中切换引擎类型或修改云端配置字段时触发引擎重建（带脏检查，值未变不触发）

> 引擎选型详情、候选方案对比、演进路径见 [ASR 引擎技术选型文档](asr-engine-selection.md)。

### 3.4 LLMService — 云端润色

**职责**: 将转写原文发送到 LLM API 进行润色。

**实现方案**: `URLSession` 调用 OpenAI 兼容接口（`/v1/chat/completions`）。

- **默认服务商**: 阿里百炼（`dashscope.aliyuncs.com`）
- **默认模型**: `qwen-turbo`
- **接口格式**: OpenAI 兼容，设计为可切换服务商（只需改 endpoint + API key + model）
- **润色 System Prompt**: 每次请求携带，定义润色规则（去语气词、结构化、精简语言）。Prompt 可在设置中编辑，方便持续调优润色效果
- 超时: 10 秒
- 非 streaming，等完整响应返回

**请求结构**:
```
messages: [
  { role: "system", content: "<润色 System Prompt>" },
  { role: "user",   content: "<转写原文>" }
]
```

**关键接口**:
```swift
class LLMService {
    func polish(text: String) async throws -> String
}
```

**配置结构**:
```swift
struct LLMConfig {
    var endpoint: String   // API base URL
    var apiKey: String
    var model: String
    var systemPrompt: String
}
```

### 3.5 TextOutputManager — 文本输出

**职责**: 将润色结果填入目标位置。

**实现方案**: macOS Accessibility API（`AXUIElement`）。

**焦点分类**:

通过 AX API 获取焦点应用和焦点元素，分类为三种上下文：

| 上下文 | 条件 | 后续处理 |
|--------|------|----------|
| `editableText` | 焦点元素为已知文本角色或标记 editable | 多级写入策略 |
| `nonEditable` | 焦点元素存在但不可编辑 | 弹窗展示 |
| `unavailable` | 无法获取焦点应用或焦点元素（Electron 等 AX 不透明应用） | 按 `UnavailableFocusStrategy` 处理 |

焦点应用获取失败时，回退到 `NSWorkspace.frontmostApplication` → `AXUIElementCreateApplication`。

**写入策略（editableText，逐级降级）**:

| 级别 | 方法 | 说明 |
|------|------|------|
| L1 | `AXSelectedText` 直写 | 零剪贴板干扰，替换选中或插入光标位置 |
| L2 | `AXValue` + `AXSelectedTextRange` 拼接 | 读取完整文本值，在选区位置替换后整体写回 |
| L3 | 剪贴板 + `Cmd+V`（带验证） | 操作前备份剪贴板，Cmd+V 后检查 AXValue 是否变化来验证成功 |
| 兜底 | 弹窗展示 | L1-L3 均失败时回退 |

**AX 不可用时的策略（`UnavailableFocusStrategy`）**:

当 AX 无法获取焦点元素时（如 Electron 应用、Codex、微信等），根据配置策略处理：

| 策略 | 行为 |
|------|------|
| `blindPasteOnly` | 直接剪贴板 + Cmd+V，不弹窗 |
| `blindPasteThenPopup` | 先盲粘贴，再弹窗展示（双保险） |
| `popupOnly` | 仅弹窗展示 |

- 全局默认策略可在 Settings General 标签页配置
- 特定应用有硬编码覆盖（如 Codex → blindPasteOnly，Finder → popupOnly）
- 策略通过 `ConfigManager.strategyForApp(bundleId)` 解析，per-app 覆盖优先于全局默认

**剪贴板保护**: 使用剪贴板时操作前备份内容，500ms 后若剪贴板未被其他程序修改则恢复原内容。

**关键接口**:
```swift
class TextOutputManager {
    func output(text: String) async  // 自动分类焦点 → 多级写入 / 策略处理 / 弹窗
}
```

### 3.6 FloatingIndicator — 浮动状态指示器

**职责**: 录音及处理期间在桌面显示浮动图标，全流程可见的状态反馈。

**实现方案**: `NSPanel`（`level = .floating`, `styleMask = [.nonactivatingPanel]`），不抢焦点。

- 小尺寸圆形面板（约 60x60pt），半透明背景
- 默认位置: 屏幕右下角（可拖拽调整）

**状态切换**:
| 状态 | 动画 | 触发时机 |
|------|------|----------|
| 录音中 | 麦克风图标 + 音浪扩散（呼吸效果） | 按住快捷键 |
| 处理中 | 旋转加载动画 | 松开快捷键，进入转写+润色 |
| 错误 | 错误提示（简短文字） | STT 失败等异常 |
| 隐藏 | — | 文本输出完成 / 错误提示 2 秒后 |

### 3.7 StatusBarController — 菜单栏 UI

**职责**: 菜单栏图标 + 下拉菜单。

**菜单栏图标状态**:
| 状态 | 图标 | 说明 |
|------|------|------|
| 空闲 | 麦克风图标 | 等待输入 |
| 处理中 | 加载动画 | 转写 + 润色进行中 |

> 录音和处理状态由 FloatingIndicator 负责，菜单栏仅在处理中显示加载状态。

**菜单项**:
- 状态显示（当前状态文字）
- 设置（打开设置窗口）
- 退出

### 3.8 ConfigManager — 配置管理

**职责**: 管理所有可配置项。

**存储方式**: `UserDefaults` 存普通配置，`Keychain` 存 API Key。

**可配置项**:
| 配置项 | 默认值 | 存储 |
|--------|--------|------|
| 快捷键 | Left Option | UserDefaults |
| ASR 引擎类型 | whisperLocal | UserDefaults |
| 本地模型路径 | `~/Library/Application Support/TypeFlow/Models/` | UserDefaults |
| ASR 云端 API Key | (无) | Keychain（独立条目 account: "speech-api-key"） |
| ASR 云端模型 | qwen3-asr-flash | UserDefaults |
| ASR 云端 Endpoint | 阿里百炼地址 | UserDefaults |
| LLM Endpoint | 阿里百炼地址 | UserDefaults |
| LLM Model | qwen-turbo | UserDefaults |
| LLM API Key | (无) | Keychain |
| 润色 System Prompt | 内置默认 | UserDefaults |
| AX 不可用策略 | blindPasteThenPopup | UserDefaults |
| 指示器位置 | 屏幕右下角 | UserDefaults（拖拽后记忆） |

## 4. 权限需求

| 权限 | 用途 | 配置 |
|------|------|------|
| 麦克风 | 录音采集 | Info.plist `NSMicrophoneUsageDescription` |
| 辅助功能 | 全局快捷键 + 文本选中检测/替换 | 系统设置手动授权 |

## 5. 项目结构

> 构建方案采用 SPM + shell 脚本打包 .app，具体构建流程和脚本细节以 [`docs/development-plan.md`](../development-plan.md) 为准。

```
TypeFlow/
├── Package.swift                      # SPM 项目定义
├── Sources/TypeFlow/
│   ├── main.swift                     # NSApplication.shared 入口
│   ├── App/
│   │   ├── AppDelegate.swift          # NSApplicationDelegate, 初始化各模块
│   │   └── AppState.swift             # 全局状态机
│   ├── Core/
│   │   ├── HotkeyManager.swift
│   │   ├── AudioRecorder.swift
│   │   ├── SpeechEngine.swift        # protocol + 引擎类型定义
│   │   ├── WhisperEngine.swift       # whisper.cpp 本地引擎
│   │   ├── QwenCloudEngine.swift     # 百炼 qwen3-asr 云端引擎
│   │   ├── LLMService.swift
│   │   └── TextOutputManager.swift
│   ├── UI/
│   │   ├── StatusBarController.swift
│   │   ├── FloatingIndicatorView.swift # 浮动状态指示器
│   │   ├── ResultPopupView.swift      # 结果弹窗
│   │   └── SettingsWindowController.swift  # 设置窗口（General/Speech/LLM 标签页）
│   ├── Config/
│   │   └── ConfigManager.swift
│   └── CWhisper/                      # whisper.cpp C module map
│       ├── module.modulemap
│       └── shim.h
├── App/
│   └── Info.plist                     # 唯一真源，-sectcreate 和 .app 打包均引用
├── Libraries/
│   └── whisper.cpp/                   # Git Submodule
├── scripts/
│   ├── build_app.sh                   # 一键构建 .app（自动触发 whisper 编译）
│   └── build_whisper.sh               # CMake 编译 whisper.cpp 静态库
├── docs/
│   ├── design/
│   │   ├── technical-design.md
│   │   └── asr-engine-selection.md
│   └── development-plan.md
├── HANDOFF.md
└── .gitignore
```

**注**: ASR 模型文件不入仓库，用户首次运行时引导下载到 `~/Library/Application Support/TypeFlow/Models/`。

## 6. 依赖项

| 依赖 | 方式 | 用途 |
|------|------|------|
| whisper.cpp | Git Submodule, 源码编译 | 语音转写（WhisperEngine） |

云端引擎（QwenCloudEngine）通过 URLSession 调用，无额外依赖。本地 Qwen3-ASR 引擎的依赖方案见 [ASR 引擎技术选型文档](asr-engine-selection.md)。

系统框架：AVFoundation, ApplicationServices, Security, SwiftUI。

## 7. 数据流时序

```
用户按住快捷键
  │
  ├─→ HotkeyManager.hotkeyDidPress()
  │     ├─→ AudioRecorder.startRecording()
  │     └─→ FloatingIndicator.show(.recording)
  │
用户松开快捷键
  │
  ├─→ HotkeyManager.hotkeyDidRelease()
  │     ├─→ samples = AudioRecorder.stopRecording()
  │     │
  │     ├─→ [录音 < 0.5s] 视为误触 → FloatingIndicator.hide() → 回到 Idle（不进入 Processing）
  │     │
  │     └─→ [录音 >= 0.5s] FloatingIndicator.show(.processing)
  │           │
  │           ├─→ rawText = SpeechEngine.transcribe(samples)
  │           │     └─→ [失败/空文本] FloatingIndicator.show(.error) → 2s 后 hide → Idle
  │           │
  │           ├─→ polishedText = LLMService.polish(rawText)
  │           │     └─→ [失败] 降级: polishedText = rawText（跳过润色，继续输出）
  │           │
  │           ├─→ TextOutputManager.output(polishedText)
  │           │     ├─→ [输入框 + 有选中] 替换选中文本
  │           │     ├─→ [输入框 + 无选中] 光标位置直接插入
  │           │     ├─→ [非输入框] 弹窗展示 + 复制按钮
  │           │     └─→ [替换/插入失败] 回退到弹窗展示
  │           │
  │           └─→ FloatingIndicator.hide()
```
