# TypeFlow 开发实施计划

## Context

TypeFlow 技术设计文档已完成（`docs/technical-design.md`），需要从零开始编码实现。

**关键环境约束**：当前只有 Command Line Tools（无完整 Xcode），因此采用 **SPM + shell 脚本打包 .app** 方案（TypeNo 项目 `/Users/lok666/Desktop/othercode/typeno/` 已验证此方案可行）。技术设计文档中的 `TypeFlow.xcodeproj/` 需调整为 `Package.swift`。

**前置依赖**：`brew install cmake`（whisper.cpp 编译需要）。

---

## 阶段划分（共 6 阶段，每次会话最多执行 2 阶段）

### 阶段 1：项目骨架 + 菜单栏空壳

**交付物**：运行后菜单栏出现图标，点击显示菜单（状态/设置/退出），无 Dock 图标。

- `git init` + `.gitignore`
- `Package.swift`：SPM executable target，`platforms: [.macOS(.v14)]`，`-sectcreate` 嵌入 `App/Info.plist`
- `Sources/TypeFlow/main.swift`：`NSApplication.shared` 入口，`activationPolicy(.accessory)`
- `Sources/TypeFlow/App/AppDelegate.swift`：初始化 StatusBarController
- `Sources/TypeFlow/UI/StatusBarController.swift`：`NSStatusBar` 图标 + 菜单
- `Sources/TypeFlow/Config/ConfigManager.swift`：最小骨架（UserDefaults 读写）
- `App/Info.plist`（**唯一真源**）：`LSUIElement=true`，`NSMicrophoneUsageDescription`。`-sectcreate` 和 `.app` bundle 打包均引用此文件
- `scripts/build_app.sh`：`swift build -c release` + 组装 `.app` bundle（从 `App/Info.plist` 复制）+ codesign

**参考**：TypeNo 的 `main.swift`、`Package.swift`、`build_app.sh` 架构模式

### 阶段 2：状态机 + 快捷键 + 录音

**交付物**：按住 Left Option 开始录音（控制台打印），松开停止（打印时长和 sample 数）。误触/超时规则生效。

- `Sources/TypeFlow/App/AppState.swift`：状态机 `Idle → Recording → Processing → Error → Idle`，含边界规则（重复按键忽略、<0.5s 丢弃、>5min 自动停止）
- `Sources/TypeFlow/Core/HotkeyManager.swift`：`CGEvent.tapCreate` 监听 `flagsChanged` 事件（修饰键按下/释放），默认 Left Option（keycode 58）；若用户配置非修饰键则走 keyDown/keyUp。按下时设标记，期间有其他键事件则取消触发
- `Sources/TypeFlow/Core/AudioRecorder.swift`：`AVAudioEngine` + `installTap`，`AVAudioConverter` 重采样到 16kHz mono Float32，缓存到 `[Float]`
- AppDelegate 串联：hotkeyPress → startRecording，hotkeyRelease → stopRecording → 打印信息
- 启动时 `AXIsProcessTrusted()` 权限检查；未授权时：菜单栏正常显示，快捷键/录音不可用，菜单显示"需要辅助功能权限"提示项，点击跳转系统设置。授权后无需重启即恢复（定时轮询或用户手动触发）

**阶段 2 验收检查**:
- `swift build` 编译通过
- 运行后按住 Left Option，控制台打印 "Recording started"
- 松开后打印录音时长和 sample 数量
- 快速点按（<0.5s）打印 "Discarded: too short"，不进入 Processing
- 未授权辅助功能时菜单栏显示提示

### 阶段 3：whisper.cpp 集成 + 本地转写

**交付物**：按住说中文，松开后控制台打印转写文本。

**前置**：`brew install cmake`

- `git submodule add https://github.com/ggml-org/whisper.cpp.git Libraries/whisper.cpp`
- `scripts/build_whisper.sh`：CMake 编译静态库（`-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF`）
- `Sources/TypeFlow/CWhisper/module.modulemap` + `shim.h`：暴露 whisper.h 给 Swift
- `Package.swift` 更新：`headerSearchPath` + `linkerSettings` 链接 libwhisper/libggml 静态库
- `Sources/TypeFlow/Core/WhisperEngine.swift`：参考官方 `LibWhisper.swift`，适配 macOS，强制 `zh`，串行队列线程安全，空闲 5 分钟释放（Timer + 每次转写重置）
- 模型路径：`~/Library/Application Support/TypeFlow/Models/ggml-large-v3-turbo.bin`，启动时检查

**技术风险**：SPM 链接预编译静态库的路径问题。若 `swift build` 出现 linker undefined symbol 且调整 `unsafeFlags` 路径无法解决，切换到 Makefile + swiftc 直接编译（绕过 SPM 链接限制）。

**阶段 3 验收检查**:
- `scripts/build_app.sh` 一条命令完成构建（自动触发 whisper 编译）
- 运行后按住说一句中文，松开后控制台打印转写文本
- 模型文件不存在时打印明确错误提示，不崩溃

### 阶段 4：浮动指示器 + LLM 润色

**交付物**：录音时屏幕右下角出现呼吸动画，处理时切换加载动画，完成后消失。控制台打印原文 + 润色结果。LLM 失败降级输出原文。

- `Sources/TypeFlow/UI/FloatingIndicatorView.swift`：`NSPanel(.floating, .nonactivatingPanel)`，60x60pt 圆形，`NSHostingView` 承载 SwiftUI 动画（录音=呼吸、处理=旋转、错误=文字 2s 消失）
- `Sources/TypeFlow/Core/LLMService.swift`：`URLSession` 调用 `/v1/chat/completions`，阿里百炼 qwen-turbo，System Prompt 可配置，10s 超时，失败降级 `polishedText = rawText`
- `ConfigManager` 扩展：Keychain 读写 API Key（`Security` framework）
- AppDelegate 串联完整 Processing 流程

### 阶段 5：文本输出 + 结果弹窗

**交付物**：输入框选中文本 → 替换；无选中 → 插入；非输入框 → 弹窗复制。AX 失败自动走剪贴板兜底。

- `Sources/TypeFlow/Core/TextOutputManager.swift`：
  - `AXFocusedUIElement` 获取焦点元素，判断 `AXRole`
  - 替换：`AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`
  - 插入：`AXSelectedTextRange` 定位光标 + 写入 `AXSelectedText`
  - AX 失败兜底：备份剪贴板 → 写入 → `CGEvent` 模拟 Cmd+V → 延迟恢复剪贴板
  - 最终兜底：弹窗展示
- `Sources/TypeFlow/UI/ResultPopupView.swift`：`NSPanel` 居中，显示文本 + 复制/关闭按钮

### 阶段 6：设置界面 + 收尾打磨

**交付物**：完整可用工具。设置窗口可配置所有参数，配置即时生效。

- `Sources/TypeFlow/UI/SettingsView.swift`：Tab 布局（通用/语音转写/LLM），快捷键配置、模型路径选择（NSOpenPanel）、LLM 参数 + API Key + System Prompt 编辑
- StatusBarController 增强：AppPhase 状态反映、错误信息展示
- 浮动指示器拖拽位置记忆
- `build_app.sh` 完善：版本号、图标

---

## 执行节奏

| 会话 | 阶段 | 产出 |
|------|------|------|
| 第 1 次 | 1 + 2 | 可运行菜单栏 app，按住录音松开停止 |
| 第 2 次 | 3 | whisper.cpp 集成，本地转写端到端（技术挑战最大，单独一次） |
| 第 3 次 | 4 + 5 | 完整核心流程：录音→转写→润色→输出 |
| 第 4 次 | 6 | 设置界面 + 打磨 |

## 与技术设计文档的差异

| 设计文档 | 实际方案 | 原因 |
|----------|----------|------|
| `TypeFlow.xcodeproj/` | `Package.swift` (SPM) | 无完整 Xcode，TypeNo 已验证 SPM 可行 |
| `Resources/Assets.xcassets` | `App/TypeFlow.iconset/` + icns | SPM 下 xcassets 编译复杂，iconset 更简单 |
| — | `Sources/TypeFlow/CWhisper/` | whisper.cpp C 头文件的 module map |
| — | `scripts/build_whisper.sh` | whisper.cpp CMake 预编译脚本 |
| — | `Sources/TypeFlow/App/AppState.swift` | 状态机独立文件 |

## 验证方式

每阶段完成后通过 `scripts/build_app.sh` 构建并运行 `.app`，验证该阶段交付物。

`build_app.sh` 在阶段 3 之后会自动检查 whisper 静态库是否存在，不存在则先调用 `build_whisper.sh` 编译，保证一条命令可复现完整构建。
