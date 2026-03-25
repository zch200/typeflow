# 项目交接状态
最后更新: 2026-03-25 会话主题: 阶段 1+2 实现 + 代码审核修复

## 当前进展
- [已完成] 需求讨论与技术选型
- [已完成] 技术设计文档 + 开发计划
- [已完成] Git 仓库初始化
- [已完成] 阶段 1：项目骨架 + 菜单栏空壳
- [已完成] 阶段 2：状态机 + 快捷键 + 录音（已通过人工验收）
- [待开始] 阶段 3：whisper.cpp 集成 + 本地转写

## 阶段 1+2 技术要点
- Swift 6.0.2，swift-tools-version: 6.0，严格并发模式
- HotkeyManager: CGEvent.tapCreate + MainActor.assumeIsolated
- AudioRecorder: @unchecked Sendable + NSLock 保护 installTap 回调
- 权限轮询: Task + Task.sleep（setupHotkey 返回 Bool，失败继续轮询）
- 保护: 单实例检测、麦克风权限检查、empty samples 检测、误触停引擎

## 已知 TODO
- HotkeyManager `flags.contains(.maskAlternate)` 写死 Left Option，阶段 6 改为按配置映射

## 下次会话建议
- 执行阶段 3：whisper.cpp submodule + CMake 编译 + 本地转写
- 前置：确认 `brew install cmake` 已完成
