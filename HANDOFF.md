# 项目交接状态
最后更新: 2026-03-25 会话主题: 技术设计 + 开发计划 + 仓库初始化

## 项目概述
TypeFlow — macOS 语音输入工具，按住快捷键说话 → 松开 → 本地转写 → 云端润色 → 智能填入。仅个人使用。

## 立项背景
分析了 TypeNo (github.com/marswaveai/TypeNo) 后认为功能不足（无润色、转写质量差），决定自研。

## 关键文档
- 技术设计：[`docs/technical-design.md`](docs/technical-design.md)
- 开发计划：[`docs/development-plan.md`](docs/development-plan.md)

## 关键决策
- 构建方案：**SPM + shell 脚本打包 .app**（无完整 Xcode，TypeNo 已验证可行）
- 前置依赖：`brew install cmake`（whisper.cpp 编译需要）
- TypeNo (`/Users/lok666/Desktop/othercode/typeno/`) 作为架构参考
- 仓库：`https://github.com/zch200/typeflow.git`

## 当前进展
- [已完成] 需求讨论与技术选型
- [已完成] 技术设计文档
- [已完成] 开发计划（6 阶段，4 次会话）
- [已完成] Git 仓库初始化 + 远程关联
- [待开始] 阶段 1+2：项目骨架 + 状态机 + 快捷键 + 录音

## 下次会话建议
- 读 `docs/development-plan.md` 了解完整计划
- 执行阶段 1+2，参考 TypeNo 的 SPM 架构模式
- 交付物：可运行菜单栏 app，按住 Left Option 录音松开停止
