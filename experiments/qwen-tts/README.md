# 听书引擎：Qwen3-TTS + qwentts.cpp

听书用 Qwen3-TTS 0.6B 的 CustomVoice 模型（自带命名音色），由 qwentts.cpp 的
`tts-server` 运行。app 在第一次朗读时把它作为子进程启动，空闲 3 分钟后关掉
（`app/rust/src/api/tts.rs`）。

| 部分 | 来源 | 大小 |
|---|---|---|
| 引擎 | qwentts.cpp `177925e`（ggml `2be5947`）+ `qwentts.patch`，Vulkan 编译；GitHub release `tts-engine-1` | `tts-server.exe` 一个文件，48 MB（zip 15 MB） |
| 说话模型 | `qwen-talker-0.6b-customvoice-Q8_0.gguf`，来自 Serveurperso/Qwen3-TTS-GGUF，原样放在 HF `ianhaimo/edgenovel-qwen-tts` | 969 MB |
| 编解码器 | `qwen-tokenizer-12hz-dec-Q8_0.gguf`：同一来源的 `qwen-tokenizer-12hz-Q8_0.gguf` 去掉编码器，见下文；同上 HF 仓库 | 201 MB |

## 实测（笔记本 RTX 4060，Vulkan）

- 启动加载约 3 秒。
- 12 秒的句子约 2.2 秒合成完（RTF 约 0.2）。
- 只用 CPU 时 RTF 约 1.2（OpenMP 已关）。
- 说话时显存峰值约 1.3 GB，进程内存峰值约 1.8 GB。整句解码时是 3.5 GB 和 4.1 GB，打补丁之前显存峰值是 3.9 GB。
- 只用 CPU 时进程内存峰值约 1.5 GB（整句解码时 3.1 GB）。

## 补丁

`qwentts.patch` 加了三个环境变量，app 启动引擎时都会设置：

- `QWEN_TTS_CTX`：talker 的 KV 缓存长度。引擎默认 4096，听书一次只说一句，app 设成 1024。
  请求写满缓存时停止，不报错。
- `QWEN_TTS_KV=f16`：KV 缓存用 F16（引擎原本是 F32）。1024 长度下从 224 MB 降到 112 MB。
- `QWEN_TTS_EMBD_MMAP`：文字词表（15 万行，Q8 下 331 MB，占说话模型的三分之一）不再上传显存，
  留在文件映射里由 CPU 按需读取。每句只用到几十行，系统也只调入这几页。

## 流式解码

app 请求 `response_format: "pcm"`：编解码器跟着说话模型一段一段地解码，而不是整句生成完再一次解码，
峰值内存因此少了 2 GB 多，速度也稍快。引擎流式返回 16 位 24 kHz 单声道 PCM，app 加上 WAV 头再播放或缓存。
声音和整句解码不是逐字节相同（信噪比约 36 dB），试听听不出区别。

## 编解码器去掉编码器

编解码器里的编码器（`tok_enc.*` 张量）把参考音频转成编码，只在克隆音色时用。命名音色用不到它，
引擎也只在克隆时才加载它。去掉以后文件从 291 MB 降到 201 MB，解码出来的声音逐字节相同：

```
python strip_encoder.py qwen-tokenizer-12hz-Q8_0.gguf qwen-tokenizer-12hz-dec-Q8_0.gguf
```

## 编译

需要 VS 2022 Build Tools 和 Vulkan SDK。

```
git clone --recurse-submodules https://github.com/ServeurpersoCom/qwentts.cpp
cd qwentts.cpp && git checkout 177925e && git submodule update
git apply ..\qwentts.patch
cd .. && build_engine.bat qwentts.cpp C:\qtb
```

C++ 运行库静态链接，OpenMP 也关掉了，因为 `vcomp140.dll` 没有静态版本。
exe 只依赖每个显卡驱动都会装的 `vulkan-1.dll`。

## 安装

把引擎 zip 解压到 `%APPDATA%\com.novel\novel\tts\qwen-tts\`，两个 `.gguf` 放在
`tts\` 里。app 按文件名查找：
- `tts-server.exe`
- `qwen-talker-*customvoice*.gguf`
- `qwen-tokenizer-*.gguf`

AI 设置的「朗读引擎」「中文语音」两行也会下载到同样的位置。

## 音色

CustomVoice 里以中文为母语的音色：
- uncle_fu（男声，低沉）
- serena（女声，温柔）
- vivian（女声，明亮）
- dylan（北京话）
- eric（四川话）

语速由播放端调节，引擎本身没有语速参数。

## 许可

- 模型和编解码器：Apache-2.0（Qwen 团队）
- qwentts.cpp 和 ggml：MIT

zip 里附带了这两个 MIT 许可和补丁。
