import 'package:flutter/material.dart' as material;

/// Languages supported by the application chrome. Book text is never
/// translated; this only changes menus, controls, status messages and help.
enum AppLanguage { simplifiedChinese, english }

extension AppLanguageInfo on AppLanguage {
  String get code => switch (this) {
    AppLanguage.simplifiedChinese => 'zh',
    AppLanguage.english => 'en',
  };

  material.Locale get locale => material.Locale(code);
}

const _english = <String, String>{
  '小说阅读器': 'Novel Reader',
  '书架': 'Library',
  '设置': 'Settings',
  '阅读': 'Reading',
  '本地 AI': 'Local AI',
  '数据与隐私': 'Data & Privacy',
  '关于': 'About',
  '版本': 'Version',
  '语言': 'Language',
  '界面语言': 'App language',
  '简体中文': 'Simplified Chinese',
  '英语': 'English',
  '跟随系统': 'System default',
  '取消': 'Cancel',
  '关闭': 'Close',
  '保存': 'Save',
  '删除': 'Delete',
  '清空': 'Clear',
  '重试': 'Retry',
  '返回': 'Back',
  '停止': 'Stop',
  '退出': 'Exit',
  '导入': 'Import',
  '下载': 'Download',
  '暂停': 'Pause',
  '继续': 'Resume',
  '搜索': 'Search',
  '更多': 'More',
  '全部': 'All',
  '暂无': 'None yet',
  '编辑': 'Edit',
  '完成': 'Done',
  '确认': 'Confirm',
  '开启': 'On',
  '关闭搜索': 'Close search',
  '书名或作者': 'Title or author',
  '书名': 'Title',
  '作者': 'Author',
  '找书': 'Discover',
  '导入 TXT': 'Import TXT',
  '阅读数据': 'Reading insights',
  '主题色': 'Theme',
  '书架分类': 'Library categories',
  '管理分类': 'Manage categories',
  '例如：正在读、古风、轻松': 'For example: Reading, Historical, Lighthearted',
  '新建分类': 'New category',
  '重命名': 'Rename',
  '删除分类': 'Delete category',
  '不分类': 'Uncategorized',
  '分类名称已存在': 'This category already exists',
  '编辑信息': 'Edit book details',
  '选择封面': 'Choose cover',
  '用默认封面': 'Use default cover',
  '留空恢复原名': 'Leave empty to restore the original title',
  '留空恢复原作者': 'Leave empty to restore the original author',
  '从书架移除': 'Remove from library',
  '重新指定编码': 'Choose text encoding',
  '书架是空的': 'Your library is empty',
  '拖入 TXT 文件，或点击下方按钮导入': 'Drop TXT files here, or use the button below',
  '没有可导入的 TXT 文件': 'No importable TXT files found',
  '拖到最顶端可置顶': 'Drag to the top to pin',
  'AI 运行与设备': 'AI Runtime & Device',
  '速度、电量与后台': 'Performance, battery and background work',
  '阅读字体': 'Reading fonts',
  '下载或导入字体': 'Download or import fonts',
  '书源管理': 'Book sources',
  '在线书源': 'Online sources',
  '模型、引擎与生成数据': 'Models, engines & generated data',
  '模型与生成数据': 'Models and generated data',
  '清空阅读记录': 'Clear reading history',
  '保留书籍': 'Books are kept',
  '清空全部阅读记录？': 'Clear all reading history?',
  '阅读时长、连续阅读天数和阅读画像所依据的数据都会被删除，且无法恢复。小说文件与阅读进度不会受影响。':
      'Reading time, streaks and taste-profile data will be permanently deleted. Book files and reading progress will not be affected.',
  '阅读记录已清空': 'Reading history cleared',
  '阅读助手': 'Reading Assistant',
  '回顾当前位置，继续理解正在读的故事': 'Recall context and keep track of the story',
  '当前位置': 'Current position',
  '回忆搜索': 'Recall search',
  '搜索已读内容': 'Search what you have read',
  '书籍详情': 'Book details',
  '扫书报告、人物与章节概览': 'Scan report, characters and chapter overview',
  '准备阅读助手': 'Prepare assistant',
  '后台处理': 'Background processing',
  '阅读设置': 'Reading settings',
  '阅读外观': 'Reading appearance',
  '字体、背景与翻页': 'Font, background and page mode',
  '继续阅读': 'Continue reading',
  '开始阅读': 'Start reading',
  '扫书报告': 'Scan Report',
  '分析覆盖': 'Analysis coverage',
  '章节分析': 'Chapter analysis',
  '语义索引': 'Semantic index',
  '人物构成与关系': 'Characters & relationships',
  '人物、活跃章节与关系': 'Characters, active chapters and relationships',
  '感情结构': 'Relationship structure',
  '叙事侧重': 'Story focus',
  '章节概览': 'Chapter overview',
  '排雷原文': 'Content-warning evidence',
  '查看候选原文': 'Review matching passages',
  '节奏与氛围': 'Pacing & mood',
  '后台处理设置': 'Background processing settings',
  '生成章节分析': 'Generate chapter analysis',
  '暂停章节分析': 'Pause chapter analysis',
  '继续章节分析': 'Resume chapter analysis',
  '章节分析已完成': 'Chapter analysis complete',
  '需要先下载本地 AI 模型': 'Local AI model required',
  '模型按需下载，书籍内容仍在本机处理。':
      'The model is downloaded on demand. Book content stays on this device.',
  '去下载': 'Download now',
  '无法打开这本书': 'Could not open this book',
  '没有可用章节': 'No chapters available',
  '这些是规则找到的原文依据；点击任一段可直接跳到对应章节。':
      'These passages were found by rules. Tap one to jump to its chapter.',
  '查看附近原文': 'View nearby text',
  '查看原文': 'View passage',
  '目录': 'Contents',
  '阅读中': 'Reading',
  '没有匹配的章节': 'No matching chapters',
  '上一章': 'Previous chapter',
  '下一章': 'Next chapter',
  '已经是最后一章': 'This is the last chapter',
  '标注': 'Annotations',
  '添加标注': 'Add annotation',
  '编辑标注': 'Edit annotation',
  '写下你的想法': 'Write a note',
  '标注已删除': 'Annotation deleted',
  '选择正文': 'Select text',
  '点击右上角，返回正文选择要标注的内容':
      'Use the top-right button, then select text in the reader',
  '跳转到原文': 'Jump to passage',
  '拖动选择要标注的文字': 'Drag to select text to annotate',
  '已选择正文': 'Text selected',
  '翻页方式': 'Page mode',
  '上下滚动': 'Vertical scroll',
  '左右翻页': 'Horizontal pages',
  '背景': 'Background',
  '字体': 'Font',
  '按需下载或导入本地字体': 'Download on demand or import a local font',
  '首行缩进': 'First-line indent',
  '听书': 'Read aloud',
  '暂停朗读': 'Pause narration',
  '收听本章': 'Read this chapter aloud',
  '听书设置': 'Read-aloud settings',
  '听书设置…': 'Read-aloud settings…',
  '继续朗读': 'Resume narration',
  '停止朗读': 'Stop narration',
  '去设置': 'Open settings',
  '原文': 'Exact text',
  '语义': 'Semantic',
  '书里的原话': 'Words from the book',
  '用自己的话描述情节或人物': 'Describe a scene or character in your own words',
  '语义搜索需要一个嵌入模型': 'Semantic search requires an embedding model',
  '建立索引': 'Build index',
  '正在打开书籍…': 'Opening book…',
  '正在启动本机引擎…': 'Starting local engine…',
  '中断': 'Interrupt',
  '排雷需要嵌入模型': 'Content-warning search requires an embedding model',
  '纯粹相关嫌疑片段，仅作参考': 'Potentially relevant passages for reference only',
  '氛围分布': 'Mood distribution',
  '这本书还没有章节': 'This book has no chapters',
  '还没有氛围标签': 'No mood labels yet',
  '过去半年': 'Past six months',
  '各书时长': 'Time by book',
  '换一篇': 'Try another',
  '生成阅读画像': 'Generate reading profile',
  '还没有足够的阅读记录': 'Not enough reading history yet',
  '少 ': 'Less ',
  ' 多': ' More',
  '无感后台': 'Low-impact background',
  '智能平衡': 'Balanced',
  '立即完成': 'Finish now',
  '设备空闲时分段处理，阅读时主动暂停':
      'Works in small batches while idle and pauses during reading',
  '根据设备状态调整速度，兼顾等待时间': 'Adjusts speed to device conditions and completion time',
  '使用较高性能连续完成，仍保留温度保护':
      'Runs continuously at higher performance with thermal protection',
  '后台生成已关闭': 'Background generation is off',
  '等待接通电源': 'Waiting for power',
  '设备温度较高，等待冷却': 'Device is warm; waiting to cool down',
  '正在阅读，AI 已让路': 'Reading in progress; AI is paused',
  '等待检测': 'Waiting for device check',
  '重新检测': 'Check again',
  '管理 AI 数据': 'Manage AI data',
  '仅建议阅读与语义搜索': 'Reading and semantic search only',
  '固定 8K 生成不建议': 'Fixed 8K generation not recommended',
  '固定 8K · 前台试运行': 'Fixed 8K · foreground trial',
  '标准 AI': 'Standard AI',
  '高性能 AI': 'High-performance AI',
  '后台生成': 'Background generation',
  '仅充电时运行': 'Run only while charging',
  '最低电量': 'Minimum battery',
  '空闲多久后开始': 'Start after being idle',
  '设备与模型': 'Device & model',
  '标准模型 · Qwen3 0.6B Q8': 'Standard model · Qwen3 0.6B Q8',
  '增强模型': 'Enhanced model',
  '待验证': 'Not yet validated',
  '高级设置': 'Advanced settings',
  '本次立即运行': 'Run now',
  '取消任务': 'Cancel task',
  '重试失败任务': 'Retry failed tasks',
  '取消暂停的任务？': 'Cancel paused tasks?',
  '任务会从后台队列中移除，已经生成的章节内容会保留，以后可以重新开始。':
      'Tasks will be removed from the background queue. Generated chapter data will be kept and work can be started again later.',
  '移动端支持标准': 'Mobile device guidance',
  '处理器、线程与模型驻留': 'Processor, threads and model residency',
  '处理器': 'Processor',
  '自动': 'Auto',
  '仅 CPU': 'CPU only',
  '优先 GPU': 'Prefer GPU',
  '线程上限': 'Thread limit',
  '温控倾向': 'Thermal policy',
  '保守': 'Conservative',
  '平衡': 'Balanced',
  '积极': 'Performance',
  '空闲后释放模型': 'Unload model when idle',
  '当前没有后台任务': 'No background tasks',
  '有任务失败，等待重试': 'A task failed and is waiting to retry',
  '任务已暂停': 'Tasks paused',
  '等待运行': 'Waiting to run',
  '章节摘要': 'Chapter summaries',
  'AI 引擎': 'AI Engine',
  '本地运行，不上传文本。模型按需下载。建议 8 GB 内存。':
      'Runs locally without uploading text. Models download on demand. 8 GB RAM recommended.',
  '当前版本会被保留，之后仍可再次切换回来。':
      'The current version will be kept so you can switch back later.',
  '恢复': 'Restore',
  '继续下载': 'Resume download',
  '重新下载并校验': 'Download again and verify',
  '取消未完成下载': 'Cancel incomplete download',
  '恢复旧版': 'Restore previous version',
  '删除模型': 'Delete model',
  '取消下载': 'Cancel download',
  '管理版本': 'Manage versions',
  '推理引擎 · llama.cpp': 'Inference engine · llama.cpp',
  '模型 · Qwen3 0.6B (Q8) — 摘要 / 氛围':
      'Model · Qwen3 0.6B (Q8) — summaries / mood',
  '嵌入模型 · BGE small 中文 — 语义搜索':
      'Embedding model · BGE small Chinese — semantic search',
  '朗读引擎 · sherpa-onnx': 'Narration engine · sherpa-onnx',
  '中文语音 · Kokoro（8 音色，含男声旁白）':
      'Chinese voices · Kokoro (8 voices, including male narration)',
  '字体选项': 'Font options',
  '删除字体': 'Delete font',
  '以后仍可重新下载。小说和阅读设置不会被删除。':
      'You can download it again later. Books and reading settings will not be deleted.',
  '书源': 'Book sources',
  '从文件导入': 'Import from file',
  '粘贴导入': 'Paste to import',
  '书源 JSON，或一个书源链接': 'Book-source JSON or a source URL',
  '算了': 'Keep it',
  '正在校验书源': 'Checking book sources',
  '全部重新校验': 'Check all again',
  '正在问遍所有书源': 'Searching all sources',
  '正在读取目录…': 'Loading contents…',
  '正在数…': 'Counting…',
  'AI 生成数据': 'AI-generated data',
  '全部 AI 生成数据': 'All AI-generated data',
  '暂无 AI 生成数据': 'No AI-generated data',
  '还没有生成任何 AI 数据': 'No AI-generated data yet',
  '摘要、氛围与索引': 'Summaries, mood and index',
  '摘要与氛围': 'Summaries and mood',
  '这些内容都可以重新生成，小说原文与阅读记录不会出现在这里。':
      'All of this data can be regenerated. Book text and reading history are not stored here.',
  '只会删除可重新生成的 AI 数据，不会删除小说文件或阅读记录。':
      'Only regenerable AI data will be deleted. Books and reading history are kept.',
  '按书管理': 'Manage by book',
  '全部删除': 'Delete all',
  '删除摘要与氛围': 'Delete summaries and mood',
  '删除语义索引': 'Delete semantic index',
  '推理引擎': 'Inference engine',
  '嵌入模型': 'Embedding model',
  '摘要模型': 'Summary model',
  '朗读引擎': 'Narration engine',
  '中文语音': 'Chinese voices',
  '正在下载': 'Downloading',
  '下载中断，可继续': 'Download interrupted; can resume',
  '下载失败，点按重试': 'Download failed; tap to retry',
  '已暂停，可继续': 'Paused; can resume',
  '已校验': 'Verified',
  '无需下载': 'No download required',
  '没有可恢复的旧版本': 'No previous version available',
  '没有可用的下载地址': 'No download URL available',
  '文件校验失败，已保留当前模型': 'File verification failed; the current model was kept',
  '文件大小异常，可能下载不完整': 'Unexpected file size; download may be incomplete',
  '固定 Q8，不自动降为 Q4': 'Fixed Q8; never falls back to Q4 automatically',
  '不影响模型与 8K 上下文。': 'Does not change the model or 8K context.',
  '允许后台生成': 'Allow background generation',
  '关闭后只手动运行': 'When off, tasks run only when started manually',
  '电量与空闲条件': 'Battery and idle conditions',
  '减少电池消耗': 'Reduce battery use',
  '运行方式': 'Run mode',
  '空闲时分段处理，阅读时暂停，优先保持低温':
      'Runs in small idle-time batches, pauses during reading, and prioritizes lower temperature',
  '自动调整处理速度，兼顾等待时间与设备负担':
      'Automatically balances completion time and device load',
  '连续处理，使用较高性能；温度过高仍会暂停':
      'Runs continuously at higher performance and still pauses when too warm',
  '通常保持自动即可': 'Auto is recommended for most devices',
  '这些任务在后台逐章完成，可以暂停和继续。':
      'These tasks run chapter by chapter in the background and can be paused or resumed.',
  '正在检测设备': 'Checking device',
  '暂时无法读取设备状态': 'Device status is temporarily unavailable',
  '内存容量不可用': 'Memory information unavailable',
  '电源状态不可用': 'Power status unavailable',
  '空闲状态不可用': 'Idle status unavailable',
  '已接通电源': 'Connected to power',
  '当前识别为': 'Currently detected as',
  '尚未开始': 'Not started',
  '尚未开始阅读': 'Not started reading',
  '未阅读': 'Unread',
  '已读完': 'Completed',
  '定位最近阅读': 'Go to latest reading position',
  '扫描': 'Scan',
  '准备报告': 'Prepare report',
  '人物': 'Characters',
  '人物图谱': 'Character graph',
  '人物图谱 ·': 'Character graph ·',
  '感情线': 'Romance',
  '事业线': 'Career',
  '升级线': 'Progression',
  '很少': 'Very little',
  '较少': 'Little',
  '中等': 'Moderate',
  '较多': 'A lot',
  '很多': 'Very high',
  '高可信': 'High confidence',
  '中等可信': 'Medium confidence',
  '有限依据': 'Limited evidence',
  '证据不足': 'Insufficient evidence',
  '无': 'None',
  '感情结构暂时无法生成': 'Relationship structure is not available yet',
  '感情结构生成失败，可稍后重试':
      'Relationship structure could not be generated; try again later',
  '明确伴侣': 'Confirmed partner',
  '明确亲密关系': 'Confirmed intimate relationship',
  '恋爱互动': 'Romantic interaction',
  '感情表达': 'Romantic expression',
  '亲密互动': 'Intimate interaction',
  '婚姻关系': 'Marriage',
  '双向感情': 'Mutual affection',
  '多人关系原文': 'Multi-person relationship evidence',
  '原文依据': 'Source evidence',
  '关系依据': 'Relationship evidence',
  '直接关系依据': 'Direct relationship evidence',
  '无同场关系': 'No shared-scene relationship',
  '不是人物，已移除': 'Removed: not a character',
  '重新扫描': 'Scan again',
  '重新分析': 'Analyze again',
  '正在扫描人物…': 'Scanning characters…',
  '正在核对全书人物与感情关系…': 'Reviewing characters and relationships across the book…',
  '点一个人查看': 'Select a character to inspect',
  '还没认出足够的人物': 'Not enough characters identified yet',
  '还没总结': 'Not summarized yet',
  '未总结': 'Not summarized',
  '没有可供判断的候选原文': 'No candidate passages available',
  '可能包含未读内容。': 'May include unread content.',
  '排雷仅展示相关嫌疑片段，仅作参考。':
      'Content warnings show potentially relevant passages for reference only.',
  '氛围标签': 'Mood labels',
  '平静': 'Calm',
  '轻松': 'Lighthearted',
  '温馨': 'Warm',
  '愉快': 'Cheerful',
  '热血': 'Exciting',
  '紧张': 'Tense',
  '悬疑': 'Suspenseful',
  '压抑': 'Oppressive',
  '悲伤': 'Sad',
  '总时长': 'Total time',
  '连续阅读': 'Reading streak',
  '阅读画像': 'Reading profile',
  '尚无阅读记录': 'No reading history yet',
  '让本地 AI 根据阅读记录，整理一份只属于你的阅读观察。':
      'Let local AI turn your reading history into a personal reading profile.',
  '近 7 天': 'Past 7 days',
  '什么都没搜到': 'No results found',
  '只搜索已读内容': 'Search read content only',
  '先为这本书建立索引': 'Build an index for this book first',
  '建立全文检索': 'Build full-text index',
  '暂停全文检索': 'Pause full-text indexing',
  '继续全文检索': 'Resume full-text indexing',
  '全文检索': 'Full-text search',
  '全文检索已完成': 'Full-text index complete',
  '粘贴书源': 'Paste book source',
  '导入书源 JSON': 'Import book-source JSON',
  '还没有书源': 'No book sources yet',
  '未记录校验': 'Not checked',
  '自动检测': 'Auto-detect',
  '最全': 'Most complete',
  '正在比较各源…': 'Comparing sources…',
  '来源：': 'Source: ',
  '比一比': 'Compare',
  '书名全字匹配': 'Exact title match',
  '字体不会随应用安装。需要哪一款再下载，也可以导入自己的 TTF / OTF。':
      'Fonts are not bundled. Download only what you need or import your own TTF / OTF file.',
  '本地字体': 'Local font',
  '系统默认': 'System default',
  '思源宋体': 'Source Han Serif',
  '霞鹜文楷': 'LXGW WenKai',
  '站酷快乐体': 'ZCOOL KuaiLe',
  '马善政毛笔体': 'Ma Shan Zheng',
  '龙藏体': 'Long Cang',
  '端正、有书卷气，适合长篇阅读': 'Formal and bookish, suited to long reading sessions',
  '温柔自然，像认真写下的手稿': 'Natural and gentle, like careful handwriting',
  '圆润俏皮，适合轻松、可爱的故事': 'Rounded and playful for lighthearted stories',
  '灵动的毛笔字，适合武侠与古风':
      'Expressive brush lettering for wuxia and historical fiction',
  '洒脱特别，像旧信笺上的字迹': 'Distinctive, free-flowing lettering like an old letter',
  '导入字体': 'Import font',
  '选择封面图片': 'Choose cover image',
  '请确认你有权使用该字体': 'Make sure you have permission to use this font',
  '听书服务': 'Read-aloud service',
  '先填服务端地址': 'Enter the server address first',
  '服务端地址': 'Server address',
  '密钥（可选）': 'API key (optional)',
  '模型（可选）': 'Model (optional)',
  '留空用服务端默认': 'Leave empty to use the server default',
  '音色': 'Voice',
  '音色名': 'Voice name',
  '测试连接': 'Test connection',
  '测试中…': 'Testing…',
  '连接正常': 'Connection successful',
  '连不上服务端，检查地址与端口': 'Could not reach the server; check its address and port',
  '地址格式不对，应形如 http://192.168.1.8:8880':
      'Invalid address; use a format such as http://192.168.1.8:8880',
  '服务端没有及时响应': 'The server did not respond in time',
  '服务端返回了空音频': 'The server returned empty audio',
  '请求失败': 'Request failed',
  '使用远程服务': 'Use remote service',
  '朗读走本机 Kokoro': 'Narration uses local Kokoro',
  '朗读走远程合成': 'Narration uses remote synthesis',
  '朗读语音未安装': 'Narration voice is not installed',
  '让它读': 'Read aloud',
  '准备…': 'Preparing…',
};

String translateUi(String source, material.Locale locale) {
  if (locale.languageCode != 'en' || source.isEmpty) {
    return source;
  }
  final exact = _english[source];
  if (exact != null) return exact;

  final imported = RegExp(r'^已导入 (\d+) 本$').firstMatch(source);
  if (imported != null) return 'Imported ${imported.group(1)} books';
  final chapters = RegExp(r'^搜索 (\d+) 章$').firstMatch(source);
  if (chapters != null) return 'Search ${chapters.group(1)} chapters';
  final annotations = RegExp(r'^(\d+) 条标注$').firstMatch(source);
  if (annotations != null) return '${annotations.group(1)} annotations';
  final chapterCount = RegExp(r'^(\d+) 章$').firstMatch(source);
  if (chapterCount != null) return '${chapterCount.group(1)} chapters';
  final times = RegExp(r'^(\d+) 次$').firstMatch(source);
  if (times != null) return '${times.group(1)} mentions';
  final items = RegExp(r'^(\d+) 项$').firstMatch(source);
  if (items != null) return '${items.group(1)} tasks';
  final people = RegExp(r'^(\d+) 位人物$').firstMatch(source);
  if (people != null) return '${people.group(1)} characters';
  final hours = RegExp(r'^(\d+(?:\.\d+)?) 小时$').firstMatch(source);
  if (hours != null) return '${hours.group(1)} hr';
  final minutes = RegExp(r'^(\d+) 分钟$').firstMatch(source);
  if (minutes != null) return '${minutes.group(1)} min';
  final lowBattery = RegExp(r'^电量低于 (\d+)%$').firstMatch(source);
  if (lowBattery != null) return 'Battery below ${lowBattery.group(1)}%';
  final idle = RegExp(r'^等待设备空闲 (\d+) 分钟$').firstMatch(source);
  if (idle != null) {
    return 'Waiting until device is idle for ${idle.group(1)} min';
  }
  final numberedChapter = RegExp(r'^第 (\d+) 章$').firstMatch(source);
  if (numberedChapter != null) return 'Chapter ${numberedChapter.group(1)}';
  final evidence = RegExp(r'^查看 (\d+) 条原文依据$').firstMatch(source);
  if (evidence != null) return 'View ${evidence.group(1)} source passages';
  final progress = RegExp(r'^已读 (\d+)%$').firstMatch(source);
  if (progress != null) return '${progress.group(1)}% read';
  final pages = RegExp(r'^本章 (\d+) / (\d+) 页$').firstMatch(source);
  if (pages != null) return 'Page ${pages.group(1)} of ${pages.group(2)}';
  final added = RegExp(r'^《(.+)》已加入书架$').firstMatch(source);
  if (added != null) return '“${added.group(1)}” added to the library';
  final deleteBook = RegExp(r'^删除《(.+)》？$').firstMatch(source);
  if (deleteBook != null) return 'Delete “${deleteBook.group(1)}”?';
  final opening = RegExp(r'^正在(.+)$').firstMatch(source);
  if (opening != null) {
    final translated = _english[opening.group(1)!];
    if (translated != null) return 'Running $translated';
  }
  final error = RegExp(
    r'^(清空|删除|恢复|下载|导入|重新解析|字体准备|字体导入|标注保存)失败[：:]\s*(.*)$',
  ).firstMatch(source);
  if (error != null) {
    final action = _english[error.group(1)!] ?? error.group(1)!;
    return '$action failed: ${error.group(2)}';
  }
  if (source.contains(' · ')) {
    return source
        .split(' · ')
        .map((part) => translateUi(part, locale))
        .join(' · ');
  }
  return source;
}

extension AppTranslationContext on material.BuildContext {
  String tr(String source) => translateUi(
    source,
    AppLanguageScope.maybeOf(this)?.locale ?? const material.Locale('zh'),
  );
}

class AppLanguageScope extends material.InheritedWidget {
  final AppLanguage language;

  const AppLanguageScope({
    super.key,
    required this.language,
    required super.child,
  });

  material.Locale get locale => language.locale;

  static AppLanguage? maybeOf(material.BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLanguageScope>()?.language;

  @override
  bool updateShouldNotify(AppLanguageScope oldWidget) =>
      language != oldWidget.language;
}

/// Drop-in localized text for application chrome. Set [translate] to false for
/// book text or other user-provided content.
class Text extends material.StatelessWidget {
  final String? data;
  final material.InlineSpan? textSpan;
  final material.TextStyle? style;
  final material.StrutStyle? strutStyle;
  final material.TextAlign? textAlign;
  final material.TextDirection? textDirection;
  final material.Locale? locale;
  final bool? softWrap;
  final material.TextOverflow? overflow;
  final material.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final material.TextWidthBasis? textWidthBasis;
  final material.TextHeightBehavior? textHeightBehavior;
  final material.Color? selectionColor;
  final bool translate;

  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.translate = true,
  }) : textSpan = null;

  const Text.rich(
    material.InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.translate = false,
  }) : data = null;

  @override
  material.Widget build(material.BuildContext context) {
    if (textSpan != null) {
      return material.Text.rich(
        textSpan!,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    final value = translate ? context.tr(data!) : data!;
    return material.Text(
      value,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel == null
          ? null
          : (translate ? context.tr(semanticsLabel!) : semanticsLabel),
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
