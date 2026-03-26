# 项目交接状态
最后更新: 2026-03-26 会话主题: Step 3-4 审查通过并提交

## 当前进展
- [已完成] 阶段 1-6：基础功能全部开发完成
- [已完成] ASR 引擎技术选型调研 + 设计文档 + 实施计划
- [已完成] Step 1-2：SpeechEngine protocol + WhisperEngine conformance
- [已完成] Step 3-4：ConfigManager 配置项 + QwenCloudEngine（已审查通过）
- [待开始] Step 5-6：AppDelegate 引擎工厂 + Settings UI 重构

## 关键设计决策
- SpeechEngine protocol（Sendable，非 Actor），WhisperEngine + QwenCloudEngine 两种实现
- QwenCloudEngine 为独立 actor（CPU 密集的 WAV/base64 编码不阻塞 MainActor）
- cloudSpeechApiKey 独立 Keychain 条目（account: "speech-api-key"），不与 llmApiKey 共用
- maxRecordingDuration 计算属性：本地 300s / 云端 180s（审查后从 240s 收紧，留足 10MB 余量）
- base64 编码后硬校验 9.8MB 上限，超限抛 payloadTooLarge 而非盲发请求

## 下次会话建议
- 实施计划：`.claude/plans/mellow-hatching-balloon.md`，从 Step 5 继续
- Step 5：AppDelegate 引擎工厂 + 转写调用改为 protocol 类型
- Step 6：SettingsWindowController Speech 标签页重构
