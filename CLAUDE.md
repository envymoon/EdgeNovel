# 项目规则

## 用户数据不能丢（硬性规则）

用户每天在用自己编译出来的版本读书。任何改动、任何重新编译之后，书架、阅读进度、阅读记录、标注、分类、设置都必须原样还在。

数据在哪：Windows 是 `%APPDATA%\com.novel\novel\`（`library.db` + `shared_preferences.json` + `books/` `fonts/` `ai/`），跟编译目录无关，`flutter clean` 或删掉 `app/build` 都不会动到它。

- **不改存储身份。** `Runner.rc` 的 `CompanyName "com.novel"` / `ProductName "novel"`、Android 的 `applicationId "com.novel.novel"` 决定数据目录，一改就等于换了个空书架（2026-09 改品牌名时真出过事，空目录 `com.novel\I阅读` 就是那次留下的）。改显示名、图标随意，这几个值不能动。`test/windows_release_safety_test.dart` 守着。
- **数据库只做加法。** `core/src/store.rs` 迁移只用 `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ADD COLUMN`；不 `DROP`、不改名、不重建用户表。真要删数据，只能删可重建的缓存（摘要、向量、AI 结果），而且要说明。
- **偏好设置的 key 不改名。** `SharedPreferences` 的 key 一旦发布就固定；确实要换，先读旧 key 迁到新 key 再删旧的。
- **不在启动或升级路径上删用户文件。** `books/` 里用户导入的书、`fonts/` 里导入的字体、`ai/` 里的模型，只能由用户在界面里点删除。
- **安全网：** `lib/data_guard.dart` 在新版本第一次启动、打开数据库之前，把 `library.db`(+wal) 和 `shared_preferences.json` 复制到 `backups/<时间>/`，保留最近 3 份。不要绕过或删掉它。恢复方法写在该文件开头的注释里。

## 构建环境

WSL 里没有 flutter / cargo，一律通过 `powershell.exe -NoProfile -Command` 在 Windows 侧执行；重新编译前先 `Stop-Process -Name novel`。
