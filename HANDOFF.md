# 项目交接状态
最后更新: 2026-03-25 会话主题: 阶段 4+5 实机收口 + popup / hotkey / shutdown 修复

## 当前进展
- [已完成] 阶段 1-3：骨架 + 状态机 + 快捷键 + 录音 + whisper.cpp 转写
- [已完成] 阶段 4：浮动指示器（SwiftUI 动画）+ LLM 润色（阿里百炼 qwen-turbo）
- [已完成] 阶段 5：文本输出 + 结果弹窗（已完成实机收口）
- [待开始] 阶段 6：设置界面 + 收尾打磨

## 本次会话重点：阶段 4+5 终测与收口

### 本轮实际修复项
- **Hotkey 回调线程修复**：`CGEvent tap` 回调不保证在主线程，原先 `MainActor.assumeIsolated` 会在非主线程直接 trap。改为 `Task { @MainActor in ... }` 转发处理，避免再次按 `Option` 时进程崩溃。
- **Codex / 微信 unavailable 策略收敛**：对 AX 不可见但 blind paste 实测稳定的 app，per-app override 改为 `blindPasteOnly`。当前 `com.openai.codex`、`com.tencent.xinWeChat` 走 blind paste，不再强制 popup。
- **popup 展示链路重构**：`TextOutputManager.showPopup()` 不再同步阻塞输出主流程，而是先让 `output()` 返回并隐藏处理指示器，再异步显示 popup。
- **ResultPopup 重写**：从每次新建并激活 `NSPanel`，改为复用 `NSWindow` + 更新文本内容 + `orderFrontRegardless()`。避开 accessory app 下窗口激活/创建阶段卡死的问题。
- **popup collectionBehavior 修复**：去掉互斥组合 `.canJoinAllSpaces + .moveToActiveSpace`，保留 `.moveToActiveSpace + .fullScreenAuxiliary`，修复首次 popup 时 `NSInternalInconsistencyException` 崩溃。
- **退出流程修复**：`Quit TypeFlow` 不再直接 `NSApp.terminate(nil)` 结束，而是在 `applicationShouldTerminate` 中先停掉 hotkey / task / recorder，再显式 `await whisperEngine.shutdown()` 执行 `whisper_free(ctx)`，修复退出时 ggml Metal backend 的 `GGML_ASSERT([rsets->data count] == 0)` 崩溃。
- **诊断日志补充**：为 output begin/end、indicator hide、phase idle、popup 创建/展示、shutdown begin/complete 增加日志，便于后续回归。

### 当前已验证通过的场景
- **企业微信输入框**：AX 直写成功，语音输入链路正常。
- **Codex 输入框**：blind paste 成功，处理浮窗正常关闭，可连续多次按 `Option` 录音。
- **非输入框场景（Activity Monitor）**：会弹出结果窗口；点击 `Copy` 后窗口关闭，应用后续仍可继续使用。
- **应用退出**：菜单栏点击 `Quit TypeFlow` 后，日志显示 `Shutdown: begin -> freeing whisper context -> complete`，不再出现 ggml Metal abort。

### 当前代码层面的关键决策
- `TextOutputManager` 的 unavailable 路径使用 per-app 策略，而不是全局统一处理。
- 对 Codex / 微信优先保证“可继续输入且不挂应用”，因此当前不再追求 blind paste 后再 popup 兜底。
- popup 的目标现在是“非输入框场景安全展示结果”，不是强抢前台焦点。

## 已知剩余事项
- 微信目前未重新补完整轮回归，但配置已与 Codex 一样走 `blindPasteOnly`，理论路径一致；若下次有时间可做一次轻量实测确认。
- popup 现在是功能优先版本，样式已可用但仍偏朴素；如阶段 6 有设置页，可一并顺手打磨视觉。
- LLM 仍未接入设置 UI，当前“无 API Key -> 跳过润色”属预期行为，不是 bug。

## 下次会话建议
- 直接进入阶段 6：设置界面。
- 优先项：
  - 快捷键设置
  - whisper 模型路径设置
  - LLM Endpoint / Model / API Key / System Prompt 设置
  - `UnavailableFocusStrategy` 全局设置项（以及必要的 per-app 说明）
- 如果要在阶段 6 前再做一次回归，建议只覆盖：
  - Codex 输入框
  - 企业微信输入框
  - 非输入框 popup
  - Quit TypeFlow
