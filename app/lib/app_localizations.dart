import 'package:flutter/material.dart' as material;
import 'interface_typography.dart';

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
  '书评': 'Book reviews',
  '优书网': 'Youshu',
  '优书网书评': 'Youshu reviews',
  '登录与书评更新': 'Login and review updates',
  '登录优书网': 'Log in to Youshu',
  '退出登录': 'Log out',
  '完成登录': 'Finish login',
  '验证中…': 'Checking…',
  '重新检查书评': 'Check for reviews again',
  '暂无书评 · 手动检查': 'No reviews found · Check manually',
  '暂无书评': 'No reviews found',
  '加载更多': 'Load more',
  '原站摘要': 'Source excerpt',
  '包含旧站存档和新评论，可能涉及剧透。已加载内容保存在本地，仅手动更新。':
      'Includes archived and recent reviews. May contain spoilers. Downloaded reviews are saved locally; updates are manual.',
  '在优书网网页中登录；阅读器不保存账号密码。仅主动打开书评或手动更新时查询该书。':
      'Sign in on Youshu. The reader does not store your password. Books are queried only when you open reviews or update manually.',
  '封面模式': 'Cover view',
  '详情模式': 'Detail view',
  '夜间': 'Night',
  '日间': 'Day',
  '打开书时先进扫书页': 'Open books to their detail page',
  '应用内置': 'Bundled',
  '应用内存': 'App memory',
  '内置引擎缺失，请重新安装应用': 'Bundled engine missing. Please reinstall the app.',
  '书架': 'Library',
  '设置': 'Settings',
  '阅读': 'Reading',
  'AI 管理': 'AI Manager',
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
  '外观': 'Appearance',
  '读到': 'Reading',
  '界面字体与配色': 'Interface fonts and colors',
  '界面字体': 'Interface font',
  '下载或导入界面字体': 'Download or import an interface font',
  '微软雅黑（默认）': 'Microsoft YaHei (default)',
  '苹方（默认）': 'PingFang (default)',
  '宋体': 'SimSun',
  '楷体': 'KaiTi',
  '统一界面字重': 'Uniform interface weight',
  '菜单和标题使用常规粗细': 'Use regular weight for menus and headings',
  '强调色': 'Accent color',
  '暖棕': 'Warm brown',
  '青绿': 'Teal',
  '雾蓝': 'Dusty blue',
  '梅紫': 'Plum',
  '陶红': 'Terracotta',
  '雾青': 'Mist',
  '暮紫': 'Lavender',
  '深海': 'Deep sea',
  '夜读': 'Night reading',
  '故事从这一页开始': 'The story begins on this page',
  '界面与阅读字体分别设置': 'Interface and reading fonts are set separately',
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
  'AI 生成': 'Draw with AI',
  'AI 生成封面': 'Draw a cover with AI',
  '场景': 'Setting',
  '少女': 'Girl',
  '少年': 'Boy',
  '无人物': 'No one',
  '玄幻': 'Eastern fantasy',
  '奇幻': 'Fantasy',
  '武侠': 'Wuxia',
  '仙侠': 'Xianxia',
  '都市': 'City',
  '现实': 'Everyday',
  '历史': 'Historical',
  '军事': 'Military',
  '游戏': 'Game',
  '体育': 'Sports',
  '科幻': 'Sci-fi',
  '悬疑灵异': 'Mystery',
  '轻小说': 'Light novel',
  '插画': 'Illustration',
  '人物（可多选，不选则只画风景）': 'People (any number; none draws scenery)',
  '题材': 'World',
  '在封面上印书名': 'Print the title on the cover',
  '小女孩': 'Little girl',
  '成年女性': 'Woman',
  '老婆婆': 'Old woman',
  '小男孩': 'Little boy',
  '成年男性': 'Man',
  '老爷爷': 'Old man',
  '古风': 'Classical Chinese',
  '宫廷': 'Imperial court',
  '和风': 'Japanese',
  '校园': 'School',
  '民国': 'Republic era',
  '末世': 'Post-apocalypse',
  '赛博朋克': 'Cyberpunk',
  '蒸汽朋克': 'Steampunk',
  '童话': 'Fairy tale',
  '夏日': 'Summer',
  '表情': 'Expression',
  '动作': 'Pose',
  '构图': 'Framing',
  '画风': 'Style',
  '生成': 'Draw',
  '换一张': 'Another',
  '用这张': 'Use this',
  '准备中，正在载入模型': 'Loading the model',
  '正在绘制': 'Drawing',
  '正在成图': 'Finishing',
  '在本机生成，不上传任何内容': 'Drawn on this device; nothing is uploaded',
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
  '阅读时长、阅读速度、连续阅读天数和阅读画像所依据的数据都会被删除，且无法恢复。小说文件与阅读进度不会受影响。':
      'Reading time, reading speed, streaks and taste-profile data will be permanently deleted. Book files and reading progress will not be affected.',
  '阅读记录已清空': 'Reading history cleared',
  '阅读助手': 'Reading Assistant',
  '回顾当前位置，继续理解正在读的故事': 'Recall context and keep track of the story',
  '当前位置': 'Current position',
  '搜索已读内容': 'Search what you have read',
  '阅读报告': 'Reading Report',
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
  '章间立绘': 'Chapter illustrations',
  '每隔几章，在章节之间插一张插画。画什么由书里的内容决定，读到才知道。':
      'Every few chapters, an illustration between two chapters. What it shows comes from the book; you will see when you get there.',
  '需要先下载生图引擎和模型': 'Download the image engine and model first',
  '继续绘制': 'Continue drawing',
  '轻触继续': 'Tap to continue',
  '正在画章间立绘': 'Drawing chapter illustrations',
  '已取消章间立绘': 'Chapter illustrations cancelled',
  '每隔几章插一张插画，读到才知道画了什么':
      'An illustration every few chapters, a surprise when you get there',
  '尚未生成': 'Not generated yet',
  '取消生成': 'Cancel',
  '清除已画的立绘': 'Delete illustrations',
  '清除已画的立绘？': 'Delete the illustrations?',
  '清除': 'Delete',
  '标签': 'Tags',
  '随机': 'Random',
  '身份': 'Role',
  '发色': 'Hair colour',
  '发型': 'Hairstyle',
  '眼睛': 'Eyes',
  '服饰': 'Clothes',
  '手持': 'Holding',
  '地点': 'Place',
  '时间天气': 'Time & weather',
  '景物': 'Scenery',
  '语义索引': 'Semantic index',
  '人物构成与关系': 'Characters & relationships',
  '人物、活跃章节与关系': 'Characters, active chapters and relationships',
  '感情结构': 'Relationship structure',
  '叙事侧重': 'Story focus',
  '章节概览': 'Chapter overview',
  '排雷原文': 'Content-warning evidence',
  '查看候选原文': 'Review matching passages',
  '节奏与氛围': 'Pacing & mood',
  '节奏': 'Pacing',
  '全书激烈与平缓的起伏': 'How intensity rises and falls across the book',
  '后台处理设置': 'Background processing settings',
  '生成章节分析': 'Generate chapter analysis',
  '暂停章节分析': 'Pause chapter analysis',
  '继续章节分析': 'Resume chapter analysis',
  '章节分析已完成': 'Chapter analysis complete',
  '需要先下载本地 AI 模型': 'Local AI model required',
  '需要先下载检索模型': 'Search model required',
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
  '未选择正文': 'No text selected',
  '未分析': 'Not analyzed',
  '未建立': 'Not built',
  '还没有标注': 'No annotations yet',
  '翻页方式': 'Page mode',
  '上下滚动': 'Vertical scroll',
  '左右翻页': 'Horizontal pages',
  '背景': 'Background',
  '字体': 'Font',
  '按需下载或导入本地字体': 'Download on demand or import a local font',
  '首行缩进': 'First-line indent',
  '行距': 'Line spacing',
  '段距': 'Paragraph spacing',
  '底栏显示全书节奏': 'Book pacing in bottom bar',
  '在阅读底栏显示全书节奏': 'Show book pacing in the reader bottom bar',
  '全书节奏 · 点按查看，长按或右键隐藏':
      'Book pacing · tap to view, long-press or right-click to hide',
  '已隐藏全书节奏': 'Book pacing hidden',
  '听书': 'Read aloud',
  '暂停朗读': 'Pause narration',
  '听书设置': 'Read-aloud settings',
  '听书设置…': 'Read-aloud settings…',
  '继续朗读': 'Resume narration',
  '停止朗读': 'Stop narration',
  '去设置': 'Open settings',
  '原文': 'Exact text',
  '语义': 'Semantic',
  '书里的原话': 'Words from the book',
  '用自己的话描述情节或人物': 'Describe a scene or character in your own words',
  '语义搜索需要一个检索模型': 'Semantic search requires a search model',
  '建立索引': 'Build index',
  '正在打开书籍…': 'Opening book…',
  '正在启动本机引擎…': 'Starting local engine…',
  '启动中…': 'Starting…',
  '先跑完章节概览，人物关系更完整': 'Finish the chapter overview for fuller relationships',
  '中断': 'Interrupt',
  '排雷需要检索模型': 'Content-warning search requires a search model',
  '纯粹相关嫌疑片段，仅作参考': 'Potentially relevant passages for reference only',
  '氛围分布': 'Mood distribution',
  '这本书还没有章节': 'This book has no chapters',
  '还没有氛围标签': 'No mood labels yet',
  '按每章全文里危机、打斗、悬念、感叹等字词的密度估算激烈程度，和这本书自己的平均比较。只看激烈与平缓，不分辨悲伤、温馨等情绪；不需要 AI 模型。':
      'Estimated from how densely each chapter uses words of danger, fighting, suspense and exclamation, compared with the book’s own average. It shows intensity only, not moods such as sadness or warmth. No AI model needed.',
  '点按曲线查看某一章': 'Tap the curve to see a chapter',
  '全书最激烈的一成': 'Among the most intense 10%',
  '较激烈': 'More intense than usual',
  '平缓': 'Calm',
  '激烈': 'Intense',
  '篇幅太短，未计算': 'Too short to measure',
  '最激烈的几段': 'Most intense stretches',
  '激烈高峰': 'Peak',
  '读到这里': 'You are here',
  '从这章读': 'Read from here',
  '全书节奏': 'Book pacing',
  '点按查看': 'Tap to view',
  '章节太少或太短，画不出节奏': 'Too few chapters to chart',
  '本地模型逐章写一句概括。在后台运行，可随时暂停，已完成的章节会保留。':
      'The local model writes a one-line summary of each chapter. Runs in the background; pause any time and finished chapters are kept.',
  '过去半年': 'Past six months',
  '各书时长': 'Time by book',
  '换一篇': 'Try another',
  '在读': 'Reading',
  '阅读速度': 'Reading speed',
  '读完章节': 'Chapters finished',
  '最长连续': 'Longest streak',
  '一天中的阅读时段': 'Time of day',
  '一周七天': 'Day of week',
  '读完': 'Finished',
  '搁置': 'Set aside',
  '没翻开': 'Not started',
  '纪录': 'Records',
  '单次最长': 'Longest sitting',
  '通常一次': 'Typical sitting',
  '读得最多的一天': 'Biggest day',
  '累计读完': 'Read in full',
  '从这一版开始记录。再读一会儿，就能算出你的速度。':
      'Recorded from this version on. Read a little longer and your speed will appear.',
  '已记录': 'Recorded',
  '需要': 'Needed',
  '有效阅读': 'Time counted',
  '近 30 天': 'Last 30 days',
  '更早': 'Before that',
  '激烈章节': 'Intense chapters',
  '平缓章节': 'Calm chapters',
  '读得最快': 'Fastest',
  '读得最慢': 'Slowest',
  '快速划过': 'Skimmed',
  '只算真正在读的时间：5 分钟没动、或每分钟不到 60 字，算作走开了；每分钟超过 3000 字，算作快速翻找。这两种都不计入，剩下的再去掉最快和最慢的各 5%。':
      'Only time spent actually reading counts. Five minutes without moving, or fewer than 60 characters a minute, counts as stepping away; more than 3,000 a minute counts as hunting through pages. Neither is included, and the fastest and slowest 5% of the rest are dropped.',
  '一': 'M',
  '二': 'T',
  '三': 'W',
  '四': 'T',
  '五': 'F',
  '六': 'S',
  '日': 'S',
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
  '不建议 AI 生成': 'AI generation not recommended',
  '前台试运行': 'Foreground trial',
  '标准 AI': 'Standard AI',
  '高性能 AI': 'High-performance AI',
  '后台生成': 'Background generation',
  '仅充电时运行': 'Run only while charging',
  '最低电量': 'Minimum battery',
  '空闲多久后开始': 'Start after being idle',
  '设备': 'Device',
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
  '摘要与索引': 'Summaries and index',
  '摘要与氛围': 'Summaries and mood',
  '这些内容都可以重新生成，小说原文与阅读记录不会出现在这里。':
      'All of this data can be regenerated. Book text and reading history are not stored here.',
  '只会删除可重新生成的 AI 数据，不会删除小说文件或阅读记录。':
      'Only regenerable AI data will be deleted. Books and reading history are kept.',
  '按书管理': 'Manage by book',
  '全部删除': 'Delete all',
  '删除摘要与氛围': 'Delete summaries and mood',
  '删除章节摘要': 'Delete chapter summaries',
  '章节摘要': 'Chapter summaries',
  '删除语义索引': 'Delete semantic index',
  'AI 引擎': 'AI engine',
  '检索模型': 'Search model',
  '分析模型': 'Analysis model',
  '朗读引擎': 'Narration engine',
  '中文语音': 'Chinese voices',
  '生图模型': 'Image model',
  '生图引擎': 'Image engine',
  '先在 设置 → AI 管理 里装好生图引擎和模型':
      'Install the image engine and model in Settings → Local AI first',
  '在书架书籍的“⋯”菜单里生成封面': 'Draw covers from a book’s “⋯” menu',
  '打开目录': 'Open folder',
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
  '允许后台生成': 'Allow background generation',
  '锁屏后继续': 'Keep going when locked',
  '锁屏运行': 'Run when locked',
  '允许阅读时后台处理': 'Work in the background while reading',
  '会降速': 'Slower',
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
  '近 7 天': 'Past 7 days',
  '什么都没搜到': 'No results found',
  '只搜索已读内容': 'Search read content only',
  '先为这本书建立索引': 'Build an index for this book first',
  '建立语义检索': 'Build semantic index',
  '暂停语义检索': 'Pause semantic indexing',
  '继续语义检索': 'Resume semantic indexing',
  '语义检索': 'Semantic search',
  '语义检索已完成': 'Semantic index complete',
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
  '朗读走本机': 'Narration runs on this device',
  '朗读走远程合成': 'Narration uses remote synthesis',
  '朗读语音未安装': 'Narration voice is not installed',
  '让它读': 'Read aloud',
  '准备…': 'Preparing…',
  '边听边合成': 'Listen now',
  '提前合成': 'Prepare ahead',
  '提前合成…': 'Prepare ahead…',
  '停止提前合成': 'Stop preparing',
  '提前合成失败': 'Preparing failed',
  '本章': 'This chapter',
  '5 章': '5 chapters',
  '10 章': '10 chapters',
  '20 章': '20 chapters',
  '已合成': 'Prepared',
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
  final minutesLeft = RegExp(r'^剩 (\d+) 分钟$').firstMatch(source);
  if (minutesLeft != null) return '${minutesLeft.group(1)} min left';
  final seconds = RegExp(r'^(\d+) 秒$').firstMatch(source);
  if (seconds != null) return '${seconds.group(1)} s';
  final days = RegExp(r'^(\d+) 天$').firstMatch(source);
  if (days != null) return '${days.group(1)} days';
  final books = RegExp(r'^(\d+) 本$').firstMatch(source);
  if (books != null) return '${books.group(1)}';
  final notes = RegExp(r'^(\d+) 条$').firstMatch(source);
  if (notes != null) return '${notes.group(1)}';
  final speed = RegExp(r'^(\d+) 字/分$').firstMatch(source);
  if (speed != null) return '${speed.group(1)} chars/min';
  final wan = RegExp(r'^约 (\d+(?:\.\d+)?) 万字$').firstMatch(source);
  if (wan != null) {
    final chars = double.parse(wan.group(1)!) * 10000;
    return chars >= 1e6
        ? '~${(chars / 1e6).toStringAsFixed(1)}M chars'
        : '~${(chars / 1000).round()}k chars';
  }
  final lowBattery = RegExp(r'^电量低于 (\d+)%$').firstMatch(source);
  if (lowBattery != null) return 'Battery below ${lowBattery.group(1)}%';
  final idle = RegExp(r'^等待设备空闲 (\d+) 分钟$').firstMatch(source);
  if (idle != null) {
    return 'Waiting until device is idle for ${idle.group(1)} min';
  }
  final everyChapters = RegExp(r'^每 (\d+) 章$').firstMatch(source);
  if (everyChapters != null) {
    return 'Every ${everyChapters.group(1)} chapters';
  }
  final readUpTo = RegExp(
    r'^已读 (\d+) 章(?: · 已索引 (\d+)/(\d+) 章)?$',
  ).firstMatch(source);
  if (readUpTo != null) {
    final indexed = readUpTo.group(2) == null
        ? ''
        : ' · ${readUpTo.group(2)}/${readUpTo.group(3)} indexed';
    return '${readUpTo.group(1)} chapters read$indexed';
  }
  final drawn = RegExp(r'^已画 (\d+) 张$').firstMatch(source);
  if (drawn != null) return '${drawn.group(1)} drawn';
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
    final typography = material.Theme.of(
      context,
    ).extension<InterfaceTypography>();
    final inheritedStyle = material.DefaultTextStyle.of(context).style;
    final effectiveStyle = inheritedStyle.merge(style);
    // Explicit font families belong to book content or font previews.
    final displayStyle = typography != null && style?.fontFamily == null
        ? effectiveStyle.copyWith(
            fontWeight: typography.uniform
                ? material.FontWeight.w400
                : ((effectiveStyle.fontWeight ?? material.FontWeight.w400)
                              .value >
                          material.FontWeight.w500.value
                      ? material.FontWeight.w500
                      : effectiveStyle.fontWeight),
          )
        : style;
    if (textSpan != null) {
      return material.Text.rich(
        textSpan!,
        style: displayStyle,
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
      style: displayStyle,
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
