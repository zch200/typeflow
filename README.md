# TypeFlow

macOS 菜单栏语音输入工具。按住快捷键说话，松开后自动转写、润色、填入光标位置。

## 工作流程

```
按住快捷键 → 录音 → whisper.cpp 本地转写 → LLM 云端润色 → 智能输出
```

- 光标在输入框 → 直接写入（替换选中 / 插入光标处）
- AX 不可用 → 剪贴板 + Cmd+V 兜底
- 非输入框 → 弹窗展示 + 一键复制

录音和处理期间屏幕上显示浮动指示器（可拖拽，位置记忆）。

## 系统要求

- macOS 14.0+
- 辅助功能权限（全局快捷键 + 文本写入）
- 麦克风权限
- whisper.cpp 模型文件（需自行下载）

## 构建

```bash
# 前置依赖
brew install cmake

# 构建 .app（自动编译 whisper.cpp + 生成图标 + 签名）
./scripts/build_app.sh

# 运行
open ./dist/TypeFlow.app
```

首次启动会自动弹出辅助功能授权弹窗。

## 模型下载

从 [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) 下载模型文件，默认路径：

```
~/Library/Application Support/TypeFlow/Models/ggml-large-v3-turbo.bin
```

也可在 Settings → Speech 中选择其他路径。

## 配置

菜单栏图标 → Settings...（快捷键 ⌘,）

| Tab | 可配置项 |
|-----|---------|
| General | 快捷键（默认 Left Option）、AX 不可用时的输出策略 |
| Speech | whisper 模型文件路径 |
| LLM | Endpoint、Model、API Key、System Prompt |

- 快捷键支持所有修饰键（Option / Control / Shift / Command / Fn / Caps Lock）
- API Key 存储在 Keychain，不落明文
- LLM 润色失败时降级输出原始转写文本

## 技术栈

纯 Swift 6 项目，无第三方依赖，仅使用系统框架。

- SPM 构建，shell 脚本打包 `.app`
- whisper.cpp 预编译静态库（Metal GPU 加速）
- AVAudioEngine 录音，16kHz mono Float32
- AX API 文本写入 + CGEvent 剪贴板兜底
- LLM 走 OpenAI 兼容接口（默认阿里百炼 qwen-turbo）

## 项目结构

```
Sources/TypeFlow/
├── main.swift                  # NSApplication 入口 + 单实例检测
├── App/
│   ├── AppDelegate.swift       # 模块协调，录音→转写→润色→输出流程
│   └── AppState.swift          # 状态机 Idle→Recording→Processing→Error
├── Config/
│   └── ConfigManager.swift     # UserDefaults + Keychain 配置管理
├── Core/
│   ├── HotkeyManager.swift     # CGEvent tap 全局快捷键
│   ├── AudioRecorder.swift     # AVAudioEngine 录音采集
│   ├── WhisperEngine.swift     # whisper.cpp actor 封装
│   ├── LLMService.swift        # /v1/chat/completions 调用
│   └── TextOutputManager.swift # AX 写入 / 剪贴板兜底 / 弹窗
└── UI/
    ├── StatusBarController.swift       # 菜单栏图标 + 菜单
    ├── FloatingIndicatorView.swift     # 浮动指示器（SwiftUI 动画）
    ├── ResultPopupView.swift           # 结果弹窗
    └── SettingsWindowController.swift  # 设置窗口
```

## License

Private project.
