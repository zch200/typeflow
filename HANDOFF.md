# 项目交接状态
最后更新: 2026-03-25 会话主题: 阶段 4+5 实现 + TextOutputManager 多轮迭代修复

## 当前进展
- [已完成] 阶段 1-3：骨架 + 状态机 + 快捷键 + 录音 + whisper.cpp 转写
- [已完成] 阶段 4：浮动指示器（SwiftUI 动画）+ LLM 润色（阿里百炼 qwen-turbo）
- [已完成] 阶段 5：文本输出 + 结果弹窗（经过 3 轮实测迭代修复）
- [待开始] 阶段 6：设置界面 + 收尾打磨

## 本次会话重点：TextOutputManager 实测问题修复（3 轮）

### 问题背景
阶段 5 核心是 TextOutputManager——将润色结果写入用户光标位置。实测发现多种场景失败：

### 第 1 轮修复（代码审查）
- **P1 剪贴板覆盖**：原先只备份 string 类型，500ms 后无条件恢复。改为备份完整 NSPasteboardItem（所有类型），恢复前检查 changeCount，仅在用户未修改时恢复。
- **P2 指示器竞态**：scheduleIndicatorHide 每次新建 Task 无取消机制。改为维护单一 indicatorHideTask，show(recording/processing) 前 cancelIndicatorHide()。
- **P2 AX 强转崩溃**：`as? AXUIElement` 在 Swift 6 是编译错误（CF 类型条件转换永远成功）。最终方案：guard let nil 检查 + `as!`（nil 已排除所以安全）。
- **产品调整**：指示器位置改屏幕底部水平居中；System Prompt 增加"必须使用简体中文"。

### 第 2 轮修复（Codex 无法写入 + popup 不弹出）
**根因**：
1. `isTextInput` 用 `AXUIElementIsAttributeSettable(kAXValueAttribute)` 判断过宽，非文本元素也返回 true → 误走写入路径 → 全部失败 → paste 盲返回 true → 结果丢失。
2. Codex（Electron）AX 完全不可见，走 unavailable → 直接 popup → 但 popup 用 `NSApp.activate()` 无参版不抢焦点 → 弹窗不可见。

**修复**：
- 重写焦点分类为 FocusContext 三态：editableText(high/medium) / nonEditable / unavailable。判断依据：AXRole + AXSubrole + AXEditable + AXSelectedText 存在性/可写性 + AXSelectedTextRange + AXValue。去掉了 AXValue settable 的过宽判断。
- AX 写入改三级：L1 kAXSelectedTextAttribute → L2 AXValue+Range 拼接写回 → L3 Cmd+V（含 150ms 后 AXValue 变化验证）。
- paste 验证：读前后 AXValue 对比；不可读时 high confidence 信任、medium 不信任。
- unavailable 路径增加 NSWorkspace.frontmostApplication fallback → AXUIElementCreateApplication(pid) → 再尝试 kAXFocusedUIElement。仍失败则 blind paste。
- popup 改用 `NSApp.activate(ignoringOtherApps: true)` + `orderFrontRegardless()` + `collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary]` + 鼠标所在屏幕居中。

### 第 3 轮修复（blind paste 永远吞掉 popup）
**根因**：unavailable 分支中 blindPaste 只要 CGEvent 能发就返回 true → popup 永不可达。对于桌面/Preview 等非编辑场景，Cmd+V 发了也无效果，结果静默丢失。

**修复**：
- ConfigManager 新增 `UnavailableFocusStrategy` 枚举：blindPasteOnly / blindPasteThenPopup(默认) / popupOnly。
- `strategyForApp(bundleId)` per-app 覆盖：Finder/Preview → popupOnly；Codex/微信/企微 → blindPasteThenPopup。
- unavailable 分支按策略分发：blindPasteThenPopup 先发 Cmd+V、等 100ms、再弹 popup（标题显示"已尝试粘贴"）。
- FocusContext.unavailable 新增 bundleId 关联值，日志打印策略名+bundleId+是否 paste+是否 popup。

## 待验证项（下次会话可实测）
- Codex 输入框：预期 blind paste 写入 + popup 兜底同时出现
- 企业微信：预期 AX 直写成功（editableText/high）或 blind paste + popup
- Finder 桌面：预期 popupOnly 直接弹窗

## 下次会话建议
- 先做一轮完整实测确认阶段 5 稳定，再进入阶段 6
- 阶段 6：设置界面（快捷键/模型路径/LLM 参数/API Key 输入/unavailable 策略选择）
- API Key 当前存 Keychain 但无 UI 入口，阶段 6 需加设置页
