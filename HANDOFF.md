# 项目交接状态
最后更新: 2026-03-27 会话主题: 常用词库功能调研与设计

## 当前进展
- [已完成] 基础功能、ASR 引擎选型、权限优化、提示词调优
- [已完成] Issue #2 调研：API 兼容性验证、竞品参考（Typeless）
- [已完成] Issue #2 设计文档 + 开发计划，经审查修正 5 项问题后定稿
- [待开始] Issue #2 开发实施（5 步）

## 关键设计决策
- qwen3-asr-flash 不支持 vocabulary_id，改用 system message 上下文增强（免费）
- 双层：ASR system message 注入 + LLM prompt 追加
- 存储：本地 JSON，原子写入，加载时规范化（去控制字符、限 50 字符/条）
- 预算：effectiveHotwords 最多 200 条，总字符上限 2000
- UI：搜索和添加分离为两个独立控件，避免误添加
- Protocol 不改签名，通过 QwenCloudEngine init + updateHotwords 传递

## 相关文档
- 设计文档：docs/design/vocabulary-feature.md
- 开发计划：.claude/plans/vocabulary-feature.md（含验证方式）

## 未解决的问题
- Issue #1: 润色强度滑动条（未开始）

## 下次会话建议
- 按计划 5 步实施：ConfigManager → QwenCloudEngine → LLMService → AppDelegate → Settings UI
- 每步 swift build 验证，最后按"验证方式"章节做功能/回退测试
