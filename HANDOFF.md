# 项目交接状态
最后更新: 2026-03-26 会话主题: 端到端验证 + 权限/终端/安装优化

## 当前进展
- [已完成] 阶段 1-6：基础功能全部开发完成
- [已完成] ASR 引擎选型全部 6 步
- [已完成] 设计文档同步更新（technical-design.md + asr-engine-selection.md）
- [已完成] 权限体验优化：AX 签名失配自动 tccutil reset、麦克风启动时请求、Keychain 弹窗抑制
- [已完成] 终端应用修复：L1 AXSelectedText 假阳性检测，终端正确降级到 Cmd+V 粘贴
- [已完成] 应用安装：build_app.sh 自动安装到 /Applications，配置开机自启

## 关键设计决策
- AX 签名失配 → tccutil reset + 重新弹出授权对话框
- 麦克风权限在启动时主动请求，避免首次授权时进程被杀
- Keychain 用 LAContext(interactionNotAllowed) 抑制旧签名条目弹窗
- L1 写入后验证 AXValue 是否变化，捕获终端等应用的假阳性
- build_app.sh 安装后清理 dist 副本，避免 Spotlight 重复

## 下次会话建议
- 手动验证云端 Qwen ASR 引擎完整流程（填入 API Key → 录音 → 转写）
- 可考虑后续：本地 Qwen3-ASR 引擎扩展（mlx-swift-asr）
