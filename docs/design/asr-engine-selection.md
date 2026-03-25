# ASR 引擎技术选型与演进规划

> 最后更新: 2026-03-25

## 1. 背景与动机

当前 TypeFlow 使用 whisper.cpp + `ggml-large-v3-turbo.bin` 作为本地 ASR 引擎。实际使用中中文识别效果差强人意（Whisper large-v3 在 WenetSpeech 会议场景 CER 高达 19%）。Qwen3-ASR 系列模型在中文识别上大幅领先，值得引入。

同时，ASR 引擎更换是一个长期会反复发生的需求（模型迭代快），需要将引擎调用逻辑抽象化，使切换成本最小。

## 2. 候选方案对比

### 2.1 模型效果

| 数据集 | Whisper-large-v3 (1.55B) | Qwen3-ASR-0.6B | Qwen3-ASR-1.7B |
|--------|--------------------------|----------------|----------------|
| WenetSpeech (net) | 9.86% CER | — | **4.97%** |
| WenetSpeech (meeting) | 19.11% | — | **5.88%** |
| AISHELL-2 | 5.06% | 5.06% | **2.71%** |
| CV-zh | 9.54% | — | **5.35%** |

注：当前项目使用的 large-v3-turbo（809M）精度低于 large-v3，实际差距更大。

### 2.2 本地方案

| 方案 | 语言 | 量化 | 0.6B 内存 | 1.7B 内存 | GPU | 适配评估 |
|------|------|------|-----------|-----------|-----|----------|
| **whisper.cpp (现有)** | C | GGML | — | — | Metal | 已集成，效果不足 |
| **mlx-qwen3-asr (Python)** | Python/MLX | 4/8bit | 0.4-0.7GB | 1.2-2.0GB | Metal | 效果最优，需 Python 运行时 |
| **mlx-swift-asr (Swift)** | Swift/MLX | 6bit+ | ~0.4GB | — | Metal | 纯 SPM 集成，项目较新待验证 |
| **antirez/qwen-asr (C)** | C | 无 | **2.8GB** | >4GB | 无(CPU) | 超出内存预算，排除 |

### 2.3 云端方案

| 方案 | 接口 | 价格 | 延迟 | 备注 |
|------|------|------|------|------|
| **百炼 qwen3-asr-flash** | OpenAI 兼容 `/v1/chat/completions` | ~0.014 元/分钟 | TTFT ~100ms + 网络 | 音频 base64 传入 |

## 3. 环境约束

- **设备**: M4 MacBook Pro, 24GB RAM
- **内存预算**: 分配给 ASR 引擎上限 **2.5GB**
- **项目现状**: 纯 Swift + whisper.cpp (C)，SPM 构建
- **优先级**: 效果 > 成本 > 架构纯净度

## 4. 技术决策

### 当前采用方案

**阶段一：抽象层 + 云端百炼 qwen3-asr-flash**

- 设计 `SpeechEngine` protocol 统一 ASR 引擎接口
- 保留现有 `WhisperEngine` 作为本地引擎
- 新增 `QwenCloudEngine` 对接百炼 qwen3-asr-flash API
- Settings UI 增加引擎类型切换
- 目的：最快验证 Qwen3-ASR 的实际效果，同时搭好引擎切换架构

### 后续演进路径

**阶段二：评估 mlx-swift-asr**

- 纯 Swift SPM 包，通过 mlx-swift 调用 Metal GPU
- 0.6B-6bit 约 400MB 内存，完全在预算内
- 1.7B 待验证内存占用和推理速度
- 若稳定可用 → 直接作为 SPM 依赖集成，最优方案

**阶段三（备选）：MLX Python CLI**

- 若 mlx-swift-asr 不够成熟
- 将 `mlx-qwen3-asr` Python 包打包为独立 CLI 工具
- Swift 通过 `Process` 调用，传入音频文件路径，stdout 返回文本
- 1.7B 4bit 约 1.6GB（含运行时），在预算内

### 被排除的方案

| 方案 | 排除原因 |
|------|----------|
| antirez/qwen-asr (C) | 不支持量化，0.6B 需 2.8GB，超出 2.5GB 内存预算 |
| PythonKit 内嵌 | 复杂度高，GIL + 签名问题，与 Swift 6 并发模型冲突 |
| MLX Python HTTP Server | 对单用户本地应用过度设计 |

## 5. 架构设计 — SpeechEngine 抽象层（阶段一）

阶段一仅实现 `whisperLocal` 和 `qwenCloud` 两种引擎。后续本地 Qwen3-ASR 引擎（mlx-swift-asr 等）作为阶段二/三引入，届时再扩展枚举和 UI。

```
┌──────────────────────────────────────────┐
│  protocol SpeechEngine: Sendable         │
│    func transcribe(samples:) async throws│
│    func shutdown() async                 │
└──────────┬───────────────────────────────┘
           │
     ┌─────┴─────────┐
     │               │
  Whisper          QwenCloud
  Engine           Engine
 (actor,          (@MainActor,
  whisper.cpp)     百炼 API)
```

### SpeechEngine Protocol

```swift
enum SpeechEngineType: Int, Sendable, CaseIterable {
    case whisperLocal = 0   // whisper.cpp 本地
    case qwenCloud = 1      // 百炼 qwen3-asr-flash
}

protocol SpeechEngine: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func shutdown() async
}
```

**设计决策**：
- 协议标记 `Sendable`（非 `Actor`）：`WhisperEngine` 是 actor，`QwenCloudEngine` 是 `@MainActor` class，两者都自动满足 `Sendable`。用 Actor 协议会强制所有实现必须是独立 actor，不够灵活。
- 不含 `engineType` 属性：引擎类型由 `ConfigManager.shared.speechEngineType` 管理，引擎本身不需要知道自己的"类型标签"。
- 各引擎保留各自的 Error 类型（`WhisperError` 等），protocol `throws` 不限定具体错误类型。

### 输入格式适配

| 引擎 | 调用方输入 | 引擎内部处理 |
|------|-----------|-------------|
| WhisperEngine | `[Float]` 16kHz mono PCM | 直接传入 whisper.cpp |
| QwenCloudEngine | `[Float]` 16kHz mono PCM | 内部转为 PCM16 WAV → base64 上传 |

调用方（AppDelegate）始终传入 `AudioRecorder.stopRecording()` 返回的 `[Float]`，格式转换是各引擎的内部职责。

### ConfigManager 扩展

```swift
// MARK: - Speech Engine（阶段一新增）
var speechEngineType: SpeechEngineType  // UserDefaults, 默认 .whisperLocal
var cloudSpeechApiKey: String?          // Keychain, account: "speech-api-key"（独立于 llmApiKey）
var cloudSpeechModel: String            // UserDefaults, 默认 "qwen3-asr-flash"
var cloudSpeechEndpoint: String         // UserDefaults, 默认 "https://dashscope.aliyuncs.com/compatible-mode"
```

**API Key 策略**：`cloudSpeechApiKey` 使用独立的 Keychain 条目，不与 `llmApiKey` 共用或 fallback。原因：
- 两个 key 可能属于不同的百炼账号或平台
- 独立存储避免了跨标签页同步的 UI 复杂度
- 用户在 Speech 标签页填一次即可，语义清晰

**Endpoint 策略**：`cloudSpeechEndpoint` 作为配置项存在于 ConfigManager，默认值与 `llmEndpoint` 相同（百炼地址）。阶段一 Settings UI **不暴露** endpoint 字段（仅显示 API Key 和 Model），高级用户可通过 `defaults write` 自行修改。

### Settings UI 变更（阶段一）

Speech 标签页增加引擎类型选择（NSPopUpButton），根据选择动态显示对应配置面板：
- **本地 Whisper** → 模型文件路径选择 + 状态标签（现有 UI）
- **云端百炼** → API Key 输入 + 模型名称输入

## 6. 百炼 qwen3-asr-flash API 对接要点

### 6.1 请求格式

**端点**: `POST {cloudSpeechEndpoint}/v1/chat/completions`

默认 `cloudSpeechEndpoint = "https://dashscope.aliyuncs.com/compatible-mode"`

```json
{
  "model": "qwen3-asr-flash",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_audio",
          "input_audio": {
            "data": "data:audio/wav;base64,<base64_encoded_audio>",
            "format": "wav"
          }
        }
      ]
    }
  ],
  "asr_options": {
    "language": "zh"
  }
}
```

- `asr_options.language = "zh"`：强制中文偏置，与本地 Whisper 的 `language = "zh"` 策略保持一致，避免语种检测开销。
- Header: `Authorization: Bearer <cloudSpeechApiKey>`, `Content-Type: application/json`
- 非流式（不设 `stream`），等完整响应返回。

**响应**: `choices[0].message.content` 为识别文本（纯文本字符串）。

### 6.2 音频编码与体积限制

百炼 OpenAI 兼容接口对 base64 音频有 **10 MB** 请求体限制。录音格式为 16kHz mono Float32 PCM（`AudioRecorder` 输出），需要在引擎内部转码后上传：

| 上传编码 | 原始数据率 | base64 后数据率 | 10 MB 可容纳时长 |
|----------|-----------|----------------|-----------------|
| Float32 WAV (audioFormat=3) | 64 KB/s | ~85 KB/s | ~122 秒（≈2 分钟） |
| **PCM16 WAV (audioFormat=1)** | **32 KB/s** | **~43 KB/s** | **~245 秒（≈4 分钟）** |

**决策：云端上传使用 PCM16（16-bit signed integer）WAV 编码。**

理由：
- 16-bit 对语音识别绰绰有余（CD 音质即 16-bit）
- 相比 Float32 体积减半，可容纳约 4 分钟录音
- Float32→Int16 转换在引擎内部完成（`sample × 32767` 截断），不影响调用方

**云端模式最大录音时长：240 秒（4 分钟）**，相比本地模式的 300 秒（5 分钟）更短。原因即 base64 编码后的 10 MB 请求体限制。此限制在 `AppDelegate` 中根据当前引擎类型动态选取。

### 6.3 WAV 编码规格

引擎内部 `encodeWAV(samples: [Float]) -> Data`：

- RIFF header: `"RIFF"` + fileSize(UInt32 LE) + `"WAVE"`
- fmt chunk: `"fmt "` + 16(UInt32) + audioFormat=**1**(UInt16, PCM) + channels=1 + sampleRate=16000 + byteRate=32000 + blockAlign=2 + bitsPerSample=16
- data chunk: `"data"` + dataSize(UInt32) + PCM16 samples(Int16 LE)
- 全部 little-endian 字节序

### 6.4 计费

按音频时长计费（25 token/秒），约 0.014 元/分钟，极低成本。

## 7. 参考资源

- [Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR 技术报告](https://arxiv.org/html/2601.21337v1)
- [mlx-qwen3-asr (Python MLX)](https://github.com/moona3k/mlx-qwen3-asr)
- [mlx-swift-asr (Swift SPM)](https://github.com/ontypehq/mlx-swift-asr)
- [antirez/qwen-asr (C)](https://github.com/antirez/qwen-asr)
- [百炼 Qwen-ASR API 文档](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)
- [百炼模型定价](https://help.aliyun.com/zh/model-studio/models)
