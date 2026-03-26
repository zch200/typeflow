# 项目交接状态
最后更新: 2026-03-26 会话主题: SpeechEngine 抽象层实施

## 当前进展
- [已完成] 阶段 1-6：基础功能全部开发完成
- [已完成] ASR 引擎技术选型调研 + 设计文档 + 实施计划
- [已完成] Step 1-2：SpeechEngine protocol + WhisperEngine conformance
- [待开始] Step 3：ConfigManager 新增 speech engine 配置项
- [待开始] Step 4：QwenCloudEngine 云端引擎实现
- [待开始] Step 5-6：AppDelegate 引擎工厂 + Settings UI 重构

## 关键设计决策
- SpeechEngine protocol（Sendable，非 Actor），WhisperEngine + QwenCloudEngine 两种实现
- 云端使用百炼 qwen3-asr-flash，PCM16 WAV 编码上传，最大录音 240 秒（10 MB base64 限制）
- cloudSpeechApiKey 独立 Keychain 条目，不与 llmApiKey 共用
- 引擎切换时若 processingTask 在执行，不 shutdown 旧引擎（任务闭包持有强引用，自然回收）

## 下次会话建议
- 实施计划：`.claude/plans/mellow-hatching-balloon.md`，从 Step 3 继续
- 每次会话最多推进 2 个 Step，编译验证后提交审查
