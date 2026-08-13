# 双平台发布说明

Windows 和 Android 必须作为两个独立的 GitHub Release 发布。它们可以使用同一个应用版本号，但标签、构建产物、验证范围和发布说明互不混用。

## 发布命名

| 平台 | Git 标签 | Release 标题 | 产物 |
| --- | --- | --- | --- |
| Windows | `windows-v1.0.0` | `Novel for Windows 1.0.0` | `Novel-Windows-x64-1.0.0.zip` |
| Android | `android-v1.0.0` | `Novel for Android 1.0.0` | `Novel-Android-arm64-v8a-1.0.0.apk` |

每个 Release 同时附带对应文件的 SHA-256 校验值。不要把调试包、模型文件、小说样本、用户数据库或构建缓存放入 Release。

## Windows 发布入口

Windows 发行物必须打包完整的 `app/build/windows/x64/runner/Release/` 目录，包括：

- `novel.exe`
- `data/`
- `flutter_windows.dll`
- `rust_lib_novel.dll`
- 其余插件 DLL 和运行文件

不能单独发布 `novel.exe`，否则应用无法启动。发布前至少验证：

1. 在一个不依赖开发工具终端的环境中双击启动。
2. 导入 TXT、打开书籍、继续阅读和退出重开。
3. 目录跳转、标注、已读标记和返回逻辑。
4. 设置页、模型按需下载、校验失败和旧版回退。
5. 安装包中不包含小说、数据库、日志、模型或个人路径。

## Android 发布入口

Android 面向普通手机的首个产物应为 ARM64 APK。现有 x86_64 调试 APK 只用于模拟器，不进入公开 Release。

正式发布前必须完成：

1. 确定唯一的 Android application ID，替换当前开发用 ID。
2. 创建并妥善备份正式签名密钥；禁止继续使用 debug 签名发布。
3. 构建 ARM64 release APK，并确认包内包含 `arm64-v8a` 原生库。
4. 在至少一台 ARM64 真机上完成安装、升级和冷启动。
5. 复测导入、继续阅读、目录跳转、标注、已读标记、设置、系统返回和后台恢复。
6. 测量模型运行时的峰值内存、耗电、温度和系统杀后台后的恢复。
7. 验证模型下载中断、校验失败和版本回退不会破坏当前可用模型。

如果只想先在 GitHub 展示项目，可以先发布源码和界面说明，把 Android 标为 Preview；不要把模拟器调试包描述成手机正式版。

## 版本同步

应用版本以 `app/pubspec.yaml` 为基准。平台可以不同日发布：例如 Windows 已达到 `1.0.0`，Android 仍为 `0.1.0-preview`。某个平台没有实际产物时，不创建该平台的空 Release。

模型版本独立于应用版本。模型通过应用内清单按需下载、校验和回退，不与 APK 或 Windows ZIP 捆绑。

## GitHub 首页建议

仓库首页只保留稳定、可验证的信息：项目理念、两层产品结构、主要功能、平台状态、设备范围和限制。测试过程截图、调试日志和实验小说不进入仓库；后续可挑选不含版权正文和个人数据的界面截图放入 `docs/images/`。
