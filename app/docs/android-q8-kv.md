# Android 原生引擎与 Q8 KV

2026-09-03：补齐 Android 原生 llama.cpp 的构建、随包安装与 Rust 启动接入。
设备端模型推理尚未验证；不能把编译通过等同于功能、内存或质量验收通过。

## 配置变更

- Android 与 Windows 的共用聊天引擎配置优先采用 Q8_0 K/V 缓存。
- 模型仍为 `Qwen3-0.6B-Q8_0.gguf`，不重新量化或下载权重。
- 上下文固定 8192，使用 `--flash-attn auto`；Q8 KV 启动失败后清理进程并重试 F16 KV。
- 提示词、人物/关系规则、章节分析、语义检索与嵌入模型均未修改。
- iOS 默认配置未变，不将 Windows 的内存收益当作 Android 实测结果。

## 接入方式

- 随 APK 内置原生 PIE 可执行文件 `libedge_llama_server.so`，支持 ARM64 / x86_64。
- llama.cpp 固定为 Windows 验证所用的 b9957 / `c4ae9a88f8884ee5a155c8349ace9ea31a58007f`。
  CMake 校验源码压缩包 SHA-256：
  `0943e7f2201ea6b300ce4125dabd6569c848a7ac8f7b703f02b41f84f4c74315`。
- 使用 NDK 编译、静态链接 llama.cpp/ggml/C++ 运行时，不依赖 Termux、桌面引擎或 root。
- APK 使用原生库提取安装。Rust 通过 `dladdr` 定位自己所在的系统安装目录，再启动
  同目录引擎，不从可写的数据目录执行下载文件。
- 继续复用现有 `LocalInferenceBackend` 的本地 HTTP 协议、任务提示词和结果解析，
  聊天与 BGE 嵌入各有一个按需启动的进程。模型权重不打进 APK。
- 本次 Android 后端为 CPU；设置页显示 CPU，不虚称支持手机 Vulkan/OpenCL。
  线程、低负载模式、任务间休息和自动卸载仍由共用层控制。
- 原生代码按 API 24 和基础 ARMv8-A 编译，不硬编码开发电脑的指令集。
  API 24 构建禁用阅读器未使用的嵌套多模型路由/外部工具子进程，避免依赖 API 28
  才有的 `posix_spawn`；视频与 Web UI 也不编入。分析算法不变。
- 引擎包含上游第三方许可，`--edge-licenses` 可输出；`--edge-self-check` 只检查启动，
  不初始化模型。这两个入口仍需在 Android 设备上执行才能验证可执行权限。

## 启停与故障恢复

- 冷加载最长等待 5 分钟；停止请求可以打断等待，超时会回收子进程。
- Q8 K/V 初始化失败，先回收进程再重试 F16 K/V；上下文仍为 8192。
  主动停止不会触发 F16 自动重启。若内存仍不足，则报告失败，不缩小上下文。
- Android 准备过程串行，避免同一时刻重复加载引擎。
- 仅监听 `127.0.0.1`；每次应用进程创建随机 API 密钥，推理接口要求鉴权。
  `/props` 用作受保护的就绪探测，不复用另一实例的公开 `/health`。
- 包装入口监测父进程；父进程消失后最多约一秒退出，不依赖 Flutter 正常清理。
- 应用进入后台时，共用队列先请求暂停，再停止 Android 引擎释放模型内存。
  因暂停导致的请求中断不记为任务失败；恢复后从已完成缓存继续。
  这不是 Android 后台服务，尚不支持系统授予的长时间后台推理。
- AI 目录保留分别对应 Q8、F16、嵌入启动的 `.novel-engine-*.log`，便于检查回退原因；
  重启对应引擎时覆盖旧日志。默认日志级别不主动打印原文提示词。
- 内置引擎随 APK 升级，不能在模型管理页单独删除；模型按需下载/校验/回退仍然独立。

## 验证限制

用户此前要求电脑 GPU 忙碌期间不启动测试模型，本次继续遵守：不启动模型或模拟器，
只进行构建、无模型单元测试与 APK 内容检查。Windows 版已由用户确认验证可用，
本次没有重建或替换 Windows 发布目录。iOS 仍需单独接入进程内推理，不能直接复用
Android 的可执行文件启动方式。

## 静态验证

- Flutter 全部 21 项单元/布局测试通过，含目录返回、标注模式、窄屏、语言、下载和回退。
- Rust 6 项无模型测试通过；6 项需要模型的测试保持忽略。
- 修改的 Dart 文件静态分析通过。
- `app/tool/verify_android_engine.ps1` 用于检查 APK 中两个架构的引擎和 Rust 库，
  与本次 strip 产物核对 SHA-256，并检查 PIE、Android 动态链接器、16KB LOAD 对齐、
  系统库依赖以及未内置 GGUF。该脚本不会运行引擎。
- Release APK：`app/build/app/outputs/flutter-apk/app-release.apk`，35,228,903 字节（约 33.6 MiB）。
  SHA-256：`778C36C92915934B6D599D4D6BA5BBF0AFD9757E6D232FA8F5BC8EADD35E34BC`。
- 两个 ABI 的原始引擎/Rust 产物与 merge 输出哈希一致，strip 输出与 APK 内文件哈希一致；
  PIE、16KB LOAD 对齐、系统依赖、随包许可、未内置 GGUF 全部通过脚本校验。
- APK 二进制 Manifest 确认 `minSdkVersion=24`、`extractNativeLibs=true`；APK v2 签名验证通过。
  仍沿用项目已有的调试签名配置，没有变更正式发布签名，也没有推送或发布 Release。
- 本次发现并修复 AGP 旧式 sourceSets 注册导致的旧引擎复用：改用与 Flutter 一致的
  `variant.sources.jniLibs.addGeneratedSourceDirectory`，通过显式 staging 任务传递产物。
  校验脚本不仅比对 APK 与 strip，还会向前核对原始编译产物，防止两个中间文件同时过期。

| APK 文件 | ARM64 字节数 | x86_64 字节数 |
| --- | ---: | ---: |
| libedge_llama_server.so | 10,631,568 | 11,771,136 |
| librust_lib_novel.so | 9,242,696 | 10,091,576 |

两个引擎均仅依赖 `libm.so`、`libdl.so`、`libc.so`。安装只提取设备匹配的 ABI。
APK 文件大小不等于模型运行内存，不用它推算 Android 的 Q8 KV 节省量。

## 下一次设备验收

1. 安装 APK，确认引擎显示为内置；先做不加载模型的启动检查。
2. 下载并校验 Q8 权重与 BGE 模型，分别验证聊天、嵌入、索引和原文检索。
3. 验证 Q8 KV 真正启用、上下文为 8192；故障注入验证 F16 回退，不能仅凭默认参数认定。
4. 对比同一书籍样本的章节摘要、人物关系与排雷候选；记录峰值内存、温度与耗电。
5. 覆盖冷加载和生成过程中的切后台、回前台、手动停止、强制关闭及任务恢复。
