# 项目交接状态
最后更新: 2026-03-26 会话主题: Step 5-6 审查通过并提交

## 当前进展
- [已完成] 阶段 1-6：基础功能全部开发完成
- [已完成] ASR 引擎技术选型调研 + 设计文档 + 实施计划
- [已完成] Step 1-2：SpeechEngine protocol + WhisperEngine conformance
- [已完成] Step 3-4：ConfigManager 配置项 + QwenCloudEngine
- [已完成] Step 5-6：AppDelegate 引擎工厂 + Settings Speech 标签页重构（已审查通过）

## 关键设计决策
- SpeechEngine protocol（Sendable，非 Actor），WhisperEngine + QwenCloudEngine 两种实现
- AppDelegate.speechEngine 类型为 `(any SpeechEngine)?`，通过 createSpeechEngine() 工厂创建
- 引擎切换语义："只影响下一次录音"，旧引擎等 processingTask 完成后再 shutdown
- 云端字段保存带脏检查，值未变不触发引擎重建

## 下次会话建议
- ASR 引擎选型计划全部完成，可进入端到端手动验证
- 可考虑后续：technical-design.md 同步更新（ASR API Key 独立条目描述）
- 可考虑后续：本地 Qwen3-ASR 引擎扩展
