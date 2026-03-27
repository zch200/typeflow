# 常用词库功能设计文档

> 最后更新: 2026-03-27 | 关联 Issue: #2

## 1. 背景与动机

提示词调优实验（prompt-tuning v3）将 LLM 润色效果推至天花板后，剩余的质量 gap 主要来自 **ASR 级别的专有名词识别错误**：

| ASR 输出 | 期望输出 | 错误类型 |
|---------|---------|---------|
| 泰普勒斯 | Typeless | 品牌名音译 |
| 克劳德 | Claude | 品牌名音译 |
| 杠 rule | /review | 命令路径 |
| 点 cloud | .Claude | 路径/品牌 |
| C M | CRM | 缩写展开 |

这类问题的本质是：ASR 模型缺乏用户领域的先验知识，无法通过通用提示词解决。需要引入用户自定义词库机制，从 ASR 识别和 LLM 润色两个阶段同时干预。

## 2. 调研结论

### 2.1 阿里云百炼热词 API 兼容性

**传统热词机制（vocabulary_id）不可用**：

百炼平台的"定制热词"功能（先创建热词列表获得 vocabulary_id，再在识别请求中引用）仅支持 Fun-ASR、Gummy、Paraformer 系列模型，**qwen3-asr-flash 不在支持列表中**。

**system message 上下文增强可用**：

qwen3-asr-flash 在模型训练阶段学习了利用 system prompt 中的 context token 作为背景知识的能力（soft biasing）。通过在 messages 中添加 system role message 传入关键词列表即可引导识别，无需预注册，无额外费用。

```json
{
  "model": "qwen3-asr-flash",
  "messages": [
    {
      "role": "system",
      "content": [{"text": "关键术语：TypeFlow, Claude, Typeless, CRM, /review"}]
    },
    {
      "role": "user",
      "content": [{"type": "input_audio", "input_audio": {"data": "...", "format": "wav"}}]
    }
  ],
  "asr_options": {"language": "zh"}
}
```

| 项目 | 情况 |
|------|------|
| 费用 | 免费（仅多一条 system message） |
| 企业认证 | 不需要 |
| 额外开通 | 不需要 |
| 效果特性 | soft biasing，模型参考但不保证 100% 命中 |
| 官方文档 | 未明确说明此用法，但技术报告和社区实践已验证 |

**参考来源**：
- [Qwen3-ASR 技术报告](https://arxiv.org/html/2601.21337v2) — context token 训练机制
- [Qwen3-ASR-Toolkit](https://github.com/QwenLM/Qwen3-ASR-Toolkit) — system message 用法示例
- [定制热词 API 参考](https://help.aliyun.com/zh/model-studio/custom-hot-words/) — 支持模型列表（不含 qwen3-asr）

### 2.2 竞品参考（Typeless）

Typeless 的词库功能特点：
- **双来源**：自动添加（从用户修改中学习）+ 手动添加
- **云端存储**：词库存在服务器端，依赖网络连接
- **UI**：分类 tab（全部/自动/手动）+ 搜索/添加/编辑/删除
- **功能开关**：`personal_auto_dictionary_on` 控制自动学习

TypeFlow 的差异化选择：
- **纯本地存储**（符合项目"无云端依赖"定位）
- **先做手动添加**，自动学习作为后续迭代
- **词库同时作用于 ASR 和 LLM 两个阶段**（Typeless 未公开其词库生效机制）

## 3. 技术方案

### 3.1 架构概览

词库在语音处理流程中的作用位置：

```
录音 → [ASR 转写 + 词库上下文] → [LLM 润色 + 词库提示] → 文本输出
              ↑                          ↑
         system message              system prompt 追加段
         引导识别偏向                   引导同音替换
```

两层协同的必要性：
- **ASR 层**：从语音信号层面引导识别，减少源头错误
- **LLM 层**：对 ASR 遗漏的错误做二次修正（如 ASR 仍输出"克劳德"，LLM 可替换为"Claude"）

### 3.2 ASR 层：system message 注入

**改动文件**：`QwenCloudEngine.swift`

在现有的 messages 数组中新增 system role message，将用户词库作为上下文传入：

```swift
// 当前（无词库）
let body: [String: Any] = [
    "model": model,
    "messages": [
        ["role": "user", "content": [["type": "input_audio", ...]]]
    ],
    "asr_options": ["language": "zh"],
]

// 改动后（有词库）
var messages: [[String: Any]] = []
if !hotwords.isEmpty {
    messages.append([
        "role": "system",
        "content": [["type": "text", "text": "关键术语：\(hotwords.joined(separator: ", "))"]]
    ])
}
messages.append(["role": "user", "content": [["type": "input_audio", ...]]])
```

**注意事项**：
- 仅云端引擎生效（本地 whisper.cpp 不支持热词）
- 词库为空时不发送 system message，避免无意义的 token 消耗
- qwen3-asr-flash 的 system content 格式为 `[{"type": "text", "text": "..."}]`（数组格式，非纯字符串）

### 3.3 LLM 层：system prompt 追加

**改动文件**：`LLMService.swift`

在构建 messages 时，将词库列表追加到 system prompt 末尾：

```swift
// LLMService.polish()
var systemPrompt = config.llmSystemPrompt

let hotwords = config.hotwords
if !hotwords.isEmpty {
    systemPrompt += "\n\n用户常用专有名词（遇到发音相近的错误写法时，替换为此处的正确写法）：\n"
    systemPrompt += hotwords.joined(separator: "、")
}

let body: [String: Any] = [
    "model": config.llmModel,
    "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": text],
    ],
    "temperature": 0.2,
]
```

**提示词设计考量**：
- 追加在 defaultSystemPrompt 之后，不侵入用户可能自定义的提示词主体
- 明确限定为"发音相近的错误写法"，避免 LLM 过度替换
- 与现有规则"修正明显的同音错字"形成呼应

### 3.4 数据存储

**存储位置**：`~/Library/Application Support/TypeFlow/hotwords.json`

选择 JSON 文件而非 UserDefaults 的理由：
- 词库可能增长到数百条，UserDefaults 不适合存储大量结构化数据
- JSON 文件便于用户手动编辑、备份、导入导出
- 与 ConfigManager 的 UserDefaults 体系解耦，避免 plist 膨胀

**数据格式**：

```json
{
  "version": 1,
  "words": [
    "TypeFlow",
    "Claude",
    "Typeless",
    "CRM",
    "/review",
    "whisper.cpp"
  ]
}
```

设计为简单的字符串列表，不引入权重等复杂概念。理由：
- qwen3-asr-flash 的 system message 是纯文本，不支持权重语法
- LLM 层也是纯文本注入，权重无意义
- 降低用户使用门槛

**持久化实现要求**：
- 写入前通过 `FileManager.createDirectory(withIntermediateDirectories: true)` 确保父目录存在
- 使用 `Data.write(to:options: .atomic)` 原子写入，避免中途失败导致文件损坏
- 写入失败时打印日志警告，不影响应用运行
- 读取时对 JSON 格式错误做容错处理，返回空数组

**词条规范化**：
- 加载时过滤空串和纯空白项
- 去除控制字符（`\n`, `\t`, `\r` 等）
- 单条长度上限 50 字符，超出截断
- 大小写无关去重（保留首次添加的原始大小写）

**注入预算控制**：
- `effectiveHotwords` 返回最多 200 条，超出时截断并打印日志警告
- ASR system message 总字符数上限 2000，超出时按条目顺序截断
- 预算控制在 `effectiveHotwords` 层统一处理，调用方无需关心

**ConfigManager 扩展**：

```swift
// MARK: - Vocabulary (Hotwords)

/// 词库开关（UserDefaults）
var hotwordsEnabled: Bool

/// 词库内容（从 JSON 文件读写，含规范化）
var hotwords: [String]

/// 生效词库（含开关检查 + 预算截断）
var effectiveHotwords: [String]

/// 添加词条（规范化 + 去重），返回 false = 已存在或无效
func addHotword(_ word: String) -> Bool
func removeHotword(_ word: String)
```

### 3.5 Settings UI

在现有 3-tab 结构中新增 **Vocabulary** 标签页：

```
┌──────────────────────────────────────────────────┐
│  General │ Speech │ LLM │ [Vocabulary]           │
├──────────────────────────────────────────────────┤
│                                                  │
│  ☑ Enable vocabulary                             │
│                                                  │
│  ┌──────────────────────────┐  ┌─────┐           │
│  │ Search...                │  │  +  │           │
│  └──────────────────────────┘  └─────┘           │
│                                                  │
│  ┌──────────────────────────────────────┐        │
│  │  TypeFlow                        ✕  │        │
│  │  Claude                          ✕  │        │
│  │  Typeless                        ✕  │        │
│  │  CRM                             ✕  │        │
│  │  /review                         ✕  │        │
│  │  whisper.cpp                     ✕  │        │
│  │                                     │        │
│  └──────────────────────────────────────┘        │
│                                                  │
│  6 words                                         │
│                                                  │
└──────────────────────────────────────────────────┘
```

**UI 元素**：
- **Enable 开关**：NSButton (checkbox)，绑定 `ConfigManager.hotwordsEnabled`
- **搜索框**：NSSearchField，仅用于实时过滤列表（不承担添加功能）
- **添加输入框 + Add 按钮**：独立的 NSTextField + 按钮，回车或点击按钮添加词条
- **词库列表**：NSTableView 单列，每行右侧有删除按钮 (✕)
- **计数标签**：底部显示词库总数

搜索和添加分为两个独立控件，避免用户在搜索时误按回车将搜索词写入词库。

**交互细节**：
- 添加时规范化：去首尾空白、去控制字符、限制 50 字符
- 添加时去重（忽略大小写比较，保留用户输入的原始大小写）
- 列表按添加顺序排列（最新在前）
- 删除无需确认（操作可逆，重新添加即可）

## 4. 改动清单

| 文件 | 改动 |
|------|------|
| `ConfigManager.swift` | 新增 hotwordsEnabled、hotwords 属性，JSON 文件读写方法 |
| `QwenCloudEngine.swift` | transcribe() 接受 hotwords 参数，构建 system message |
| `LLMService.swift` | polish() 读取词库，追加到 system prompt |
| `AppDelegate.swift` | 传递 hotwords 给 ASR 引擎调用 |
| `SettingsWindowController.swift` | 新增 Vocabulary 标签页 UI |
| `hotwords.json`（运行时生成） | 词库持久化文件 |

## 5. 边界情况与约束

| 场景 | 处理 |
|------|------|
| 词库为空 | ASR 不发送 system message，LLM 不追加词库段 |
| 词库开关关闭 | 同上，但保留词库数据（仅不生效） |
| hotwords.json 不存在 | 视为空词库，首次添加时自动创建 |
| hotwords.json 格式损坏 | 打印日志警告，视为空词库，下次保存时覆盖修复 |
| 词库条目过多 | effectiveHotwords 最多返回 200 条，ASR system message 总字符上限 2000，超出截断并打日志 |
| 词条含控制字符/超长 | 加载和添加时规范化：去控制字符、单条上限 50 字符 |
| 用户手动编辑 JSON 引入脏数据 | 读取时统一规范化：去空串、去控制字符、大小写去重 |
| 本地 Whisper 引擎 | ASR 层词库不生效（whisper.cpp 不支持），LLM 层仍然生效 |
| 用户自定义了 system prompt | 词库追加在自定义 prompt 末尾，不覆盖用户内容 |

## 6. 不做的事情（本期）

- **自动学习**：从用户修改中自动归纳高频词（Typeless 有此功能，作为后续迭代）
- **词库权重**：当前 ASR/LLM 注入方式不支持权重，统一为等权
- **词库分组/分类**：MVP 阶段用一个扁平列表即可
- **词库导入导出 UI**：用户可直接编辑 JSON 文件实现，后续按需加 UI
- **词库同步**：纯本地存储，不做云端同步

## 7. 后续演进

1. **效果验证**：上线后用现有 benchmark 数据对比有无词库的识别/润色效果差异
2. **自动学习**：分析用户对输出结果的手动修改，自动提取高频替换词对
3. **导入导出 UI**：Settings 中添加导入/导出按钮
4. **词库权重**（依赖 API 演进）：若百炼后续支持 qwen3-asr-flash 的 vocabulary_id，可升级为带权重的热词方案
