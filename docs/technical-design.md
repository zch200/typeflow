# TypeFlow 技术设计文档

## 1. 项目概述

macOS 菜单栏常驻语音输入工具。按住快捷键说话 → 松开 → 本地转写 → 云端润色 → 智能填入。

- **目标用户**: 个人使用
- **最低系统**: macOS 14.0+
- **开发语言**: Swift / SwiftUI
- **App 形态**: 菜单栏 app（LSUIElement），无主窗口

## 2. 核心流程

```
┌─────────┐    ┌───────────┐    ┌────────────┐    ┌──────────┐    ┌──────────┐
│ 按住快捷键 │───→│  录音采集   │───→│ whisper.cpp │───→│ LLM 润色  │───→│  文本输出  │
│ (按下)    │    │ AVAudioEngine│   │  本地转写   │    │ 云端 API  │    │          │
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
| 录音时长 > 5 分钟 | 自动停止录音，进入 Processing |

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

**职责**: 采集麦克风音频，输出 whisper.cpp 所需格式。

**实现方案**: `AVAudioEngine` + `inputNode`。

- 输出格式: **16kHz, mono, Float32 PCM**（whisper.cpp 原生格式）
- 硬件采样率通常非 16kHz，通过 `AVAudioConverter` 或 tap 的 format 参数进行重采样
- 使用 `installTap` 实时采集，缓存到内存 buffer
- 录音结束后返回完整 `[Float]` 数组
- **最短时长**: < 0.5 秒视为误触，丢弃（由状态机控制）
- **最长时长**: 超过 5 分钟自动停止，防止内存溢出
- 需要 **麦克风权限**

**关键接口**:
```swift
class AudioRecorder {
    func startRecording() throws
    func stopRecording() -> [Float]  // 返回 PCM samples
}
```

### 3.3 WhisperEngine — 本地语音转写

**职责**: 调用 whisper.cpp 将音频转为文字。

**实现方案**: whisper.cpp 编译为 C 库，通过 Swift Bridging Header 集成。

- **模型**: `ggml-large-v3-turbo.bin`（~1.6GB）
- **加载策略**: 首次使用时加载，最后一次转写完成后开始计时，空闲 5 分钟自动释放；每次新的转写会重置计时器
- **语言**: 强制指定 `zh`（中文），避免语言检测耗时
- 集成方式: whisper.cpp 源码作为 **Git Submodule** 加入项目，CMake 预编译为静态库，SPM 通过 linkerSettings 链接

**关键接口**:
```swift
class WhisperEngine {
    func transcribe(samples: [Float]) async throws -> String
}
```

**whisper.cpp 调用流**:
```
[首次/重新加载] whisper_init_from_file → 持有 ctx

[每次转写] whisper_full_params → whisper_full(ctx, ...) → whisper_full_n_segments/whisper_full_get_segment_text → 重置空闲计时器

[空闲 5 分钟] whisper_free(ctx) → 释放内存
```

**线程安全**: WhisperEngine 内部使用串行队列，保证同一时刻只有一个转写任务在执行。

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

**判断逻辑**:
1. 获取当前焦点应用 → 获取焦点元素（`AXFocusedUIElement`）
2. 检查焦点元素是否为文本输入（`AXRole` 为 `AXTextField` / `AXTextArea` 等）
3. 分三种情况处理:

| 情况 | 判断条件 | 行为 |
|------|----------|------|
| 替换选中 | 焦点在输入框 + `AXSelectedText` 非空 | 优先 AX 直写 `AXSelectedText`，失败则剪贴板 + `Cmd+V` |
| 直接插入 | 焦点在输入框 + 无选中文本 | 优先通过 `AXSelectedTextRange` 定位光标，写入 `AXSelectedText`（空选区写入即插入）；失败则剪贴板 + `Cmd+V` |
| 弹窗展示 | 焦点不在输入框 | 弹出浮动窗口，展示结果 + 复制按钮 |

- **写入策略**: 优先通过 `AXUIElementSetAttributeValue` 直接写入（无需触碰剪贴板）；若 AX 写入失败（部分 app 不支持），回退到剪贴板 + `Cmd+V`
- **剪贴板保护**: 使用剪贴板兜底时，操作前备份、操作后恢复
- **兜底**: 若替换/插入均失败，回退到弹窗展示
- 需要 **辅助功能权限**

**关键接口**:
```swift
class TextOutputManager {
    func output(text: String)  // 自动判断：替换 / 插入 / 弹窗
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
| Whisper 模型路径 | `~/Library/Application Support/TypeFlow/Models/` | UserDefaults |
| LLM Endpoint | 阿里百炼地址 | UserDefaults |
| LLM Model | qwen-turbo | UserDefaults |
| LLM API Key | (无) | Keychain |
| 润色 System Prompt | 内置默认 | UserDefaults |

## 4. 权限需求

| 权限 | 用途 | 配置 |
|------|------|------|
| 麦克风 | 录音采集 | Info.plist `NSMicrophoneUsageDescription` |
| 辅助功能 | 全局快捷键 + 文本选中检测/替换 | 系统设置手动授权 |

## 5. 项目结构

> 构建方案采用 SPM + shell 脚本打包 .app，具体构建流程和脚本细节以 [`docs/development-plan.md`](development-plan.md) 为准。

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
│   │   ├── WhisperEngine.swift
│   │   ├── LLMService.swift
│   │   └── TextOutputManager.swift
│   ├── UI/
│   │   ├── StatusBarController.swift
│   │   ├── FloatingIndicatorView.swift # 浮动状态指示器
│   │   ├── ResultPopupView.swift      # 结果弹窗
│   │   └── SettingsView.swift         # 设置界面
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
│   ├── technical-design.md
│   └── development-plan.md
├── HANDOFF.md
└── .gitignore
```

**注**: Whisper 模型文件（~1.6GB）不入仓库，用户首次运行时引导下载到 `~/Library/Application Support/TypeFlow/Models/`。

## 6. 依赖项

| 依赖 | 方式 | 用途 |
|------|------|------|
| whisper.cpp | Git Submodule, 源码编译 | 语音转写 |

无第三方 Swift 包依赖，全部使用系统框架（AVFoundation, ApplicationServices, Security, SwiftUI）。

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
  │           ├─→ rawText = WhisperEngine.transcribe(samples)
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
