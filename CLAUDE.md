# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TypeFlow 是一个 macOS 菜单栏常驻语音输入工具。按住快捷键说话 → 松开 → 本地 whisper.cpp 转写 → 云端 LLM 润色 → 智能填入光标位置。纯 Swift 6.0.2 项目，无第三方依赖，仅使用系统框架。

## Build & Run

```bash
# 编译（debug）
swift build

# 编译（release）
swift build -c release

# 构建 .app 包（编译 + 签名 + 打包到 dist/TypeFlow.app）
./scripts/build_app.sh

# 运行
open ./dist/TypeFlow.app
```

无测试框架，无 lint 工具。验证方式为手动运行 app 观察控制台输出。

## Architecture

**构建系统**: SPM (Swift Package Manager)，swift-tools-version: 6.0。Info.plist 通过 linker `-sectcreate` 嵌入二进制。LSUIElement app（无 Dock 图标，菜单栏即入口）。

**状态机** (`AppState`): Idle → Recording → Processing → Idle，Error 态 2 秒后自动回 Idle。所有状态转换在 MainActor 上执行。

**模块职责**:
- `main.swift` — NSApplication 入口 + 单实例检测（防重复菜单栏图标）
- `AppDelegate` — 初始化各模块，协调快捷键事件与录音/转写/润色/输出完整流程，管理权限检查和轮询恢复
- `HotkeyManager` — CGEvent.tapCreate 监听修饰键（默认 Left Option, keycode 58），检测组合键时取消触发
- `AudioRecorder` — AVAudioEngine + installTap 实时采集，AVAudioConverter 重采样到 16kHz mono Float32（whisper.cpp 原生格式）
- `WhisperEngine` — whisper.cpp actor 封装，懒加载模型，强制 zh，空闲 5 分钟释放
- `LLMService` — URLSession 调用 /v1/chat/completions（默认阿里百炼 qwen-turbo），10s 超时，失败降级输出原文
- `TextOutputManager` — AX API 检测焦点元素，替换选中/插入光标/剪贴板+Cmd+V 兜底/弹窗最终兜底
- `FloatingIndicator` — NSPanel(.floating) + SwiftUI 动画（录音=呼吸、处理=旋转、错误=图标），屏幕右下角
- `ResultPopup` — NSPanel 结果弹窗，显示文本 + 复制/关闭按钮，用于非输入框场景
- `StatusBarController` — NSStatusBar 菜单栏图标 + 动态菜单项（权限提示、状态显示）
- `ConfigManager` — UserDefaults 单例 + Keychain（API Key），存储快捷键/录音时长/模型路径/LLM 配置

## Swift 6 Concurrency Patterns

本项目使用 Swift 6 严格并发模式，以下是已确立的模式：

- **CGEvent 回调** → `MainActor.assumeIsolated`（回调在主线程但编译器不知道）
- **AVAudioEngine installTap 回调** → `@unchecked Sendable` + `NSLock` 保护共享状态
- **定时轮询** → `Task` + `Task.sleep` 替代 Timer，避免 `@Sendable` 闭包捕获问题

## Permissions

应用需要两个系统权限：
1. **辅助功能权限** — CGEvent tap 全局快捷键需要，`AXIsProcessTrusted()` 检查，需用户手动在系统设置授权
2. **麦克风权限** — AVAudioEngine 录音需要，通过 `AVCaptureDevice.requestAccess` 请求，Info.plist 中配置 `NSMicrophoneUsageDescription`

权限未授权时菜单栏显示引导提示，后台每 2 秒轮询检测权限恢复（无需重启 app）。

## Key Design Decisions

- 录音 < 0.5s 视为误触自动丢弃，> 5min 自动停止
- 音频格式固定为 16kHz mono Float32，与 whisper.cpp 原生输入格式对齐
- API Key 存储在 Keychain（Security framework），不硬编码
- 配置通过 `ConfigManager.shared` 单例管理，底层使用 UserDefaults + Keychain
- LLM 润色失败时降级输出 STT 原文（永不丢失用户输入）
- 文本输出三级策略：AX 直写 → 剪贴板+Cmd+V → 弹窗展示
- 剪贴板兜底时操作前备份、500ms 后恢复

## Documentation

- [docs/design/technical-design.md](docs/design/technical-design.md) — 完整技术设计文档（架构、模块、数据流、状态机）
- [docs/design/asr-engine-selection.md](docs/design/asr-engine-selection.md) — ASR 引擎技术选型与演进规划
- [HANDOFF.md](HANDOFF.md) — 跨会话进度交接
