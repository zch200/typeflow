# 项目交接状态
最后更新: 2026-03-25 会话主题: ASR 引擎抽象层设计

## 当前进展
- [已完成] 阶段 1-6：基础功能全部开发完成
- [已完成] ASR 引擎技术选型调研（Whisper vs Qwen3-ASR，本地 vs 云端）
- [已完成] SpeechEngine 抽象层 + 云端百炼引擎的设计文档和实施计划
- [待开始] SpeechEngine 抽象层 + QwenCloudEngine 编码实施

## 关键设计决策
- SpeechEngine protocol（Sendable，非 Actor），WhisperEngine + QwenCloudEngine 两种实现
- 云端使用百炼 qwen3-asr-flash，PCM16 WAV 编码上传，最大录音 240 秒（10 MB base64 限制）
- cloudSpeechApiKey 独立 Keychain 条目，不与 llmApiKey 共用
- 引擎切换时若 processingTask 在执行，不 shutdown 旧引擎（任务闭包持有强引用，自然回收）

## 下次会话建议
- 读取实施计划：`.claude/plans/mellow-hatching-balloon.md`
- 按 Step 1-6 顺序编码，每步可独立编译验证
- 相关设计文档：`docs/design/asr-engine-selection.md`
