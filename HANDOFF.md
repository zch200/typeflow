# 项目交接状态
最后更新: 2026-03-25 会话主题: 阶段 3 — whisper.cpp 集成 + 本地转写

## 当前进展
- [已完成] 阶段 1：项目骨架 + 菜单栏空壳
- [已完成] 阶段 2：状态机 + 快捷键 + 录音
- [已完成] 阶段 3：whisper.cpp 集成 + 本地转写（已通过代码审核）
- [待开始] 阶段 4：浮动指示器 + LLM 润色

## 阶段 3 技术要点
- whisper.cpp git submodule + CMake 静态库（Metal/BLAS 加速）
- CWhisper SPM target 暴露 C API 给 Swift
- WhisperEngine: actor 线程安全，懒加载，强制 zh，空闲 5 分钟释放
- 构建缓存：commit hash + 库文件校验，submodule 更新自动重建

## 模型下载备忘
```bash
mkdir -p ~/Library/Application\ Support/TypeFlow/Models
curl -L -o ~/Library/Application\ Support/TypeFlow/Models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```
下载后运行 `open dist/TypeFlow.app`，按住 Left Option 说中文，松开观察控制台转写输出。

## 下次会话建议
- 执行阶段 4+5：浮动指示器 + LLM 润色 + 文本输出
