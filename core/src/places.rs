//! Where a book happens — by counting, like [`crate::cast`], not by asking a
//! model to read it.
//!
//! A place name in a novel has a regular shape the way a speaker does: it
//! ends in a generic place word (城、宗、山、学院、客栈…) and it turns up after
//! the verbs that move people about (来到、前往、回到、离开…). Names are seeded
//! from there, then counted across the whole text.
//!
//! Places differ from people in how they relate. Two people share a sentence;
//! two places rarely do — the story is in one, then it goes to another. So
//! the links here are not co-occurrence but *succession*: each chapter is given
//! the place it is set in, and the graph is the trips between them. A second,
//! rarer link is *belonging*: 云岚宗后山, 加玛帝国的帝都 — a place named inside
//! another. And the book as a whole is cut into stages, the maps a web novel
//! changes as its hero moves up (镇 → 学院 → 城 → 域 → 大陆).

use crate::book::Chapter;
use std::collections::{HashMap, HashSet};

/// Generic place words a name ends in, with how big a place they make.
/// Rank only orders belonging (a 城 is inside a 国, not the other way).
const SUFFIX_LONG: &[(&str, u8)] = &[
    ("大陆", 6), ("世界", 6), ("天下", 6), ("星域", 6), ("海域", 5), ("星球", 6), ("帝国", 5),
    ("王朝", 5), ("王国", 5), ("山脉", 3), ("森林", 2), ("秘境", 2), ("遗迹", 2), ("学院", 2),
    ("大学", 2), ("中学", 2), ("小学", 2), ("高中", 2), ("书院", 2), ("学府", 2), ("宗门", 2),
    ("圣地", 2), ("禁地", 2), ("洞府", 1), ("山庄", 2), ("客栈", 1), ("酒楼", 1), ("酒店", 1),
    ("茶楼", 1), ("公司", 2), ("集团", 2), ("医院", 2), ("广场", 1), ("公园", 1), ("小区", 2),
    ("大厦", 1), ("车站", 1), ("机场", 1), ("监狱", 2), ("古城", 3), ("皇城", 3), ("皇宫", 1),
    ("王府", 1), ("山谷", 2), ("峡谷", 2), ("草原", 3), ("沙漠", 3), ("雪山", 2), ("平原", 3),
    ("古镇", 2), ("胡同", 1), ("大街", 1), ("码头", 1), ("渡口", 1), ("部落", 2), ("要塞", 2),
    ("基地", 2), ("研究所", 2), ("地区", 4),
];
const SUFFIX_ONE: &[(&str, u8)] = &[
    ("界", 6), ("洲", 6), ("域", 5), ("国", 5), ("州", 4), ("省", 4), ("郡", 4), ("城", 3),
    ("市", 3), ("县", 3), ("镇", 2), ("村", 2), ("宗", 2), ("派", 2), ("门", 2), ("宫", 1),
    ("殿", 1), ("阁", 1), ("寺", 1), ("观", 1), ("庙", 1), ("山", 2), ("岛", 2), ("谷", 2),
    ("关", 2), ("海", 3), ("湖", 2), ("江", 2), ("河", 2), ("林", 2), ("原", 3), ("漠", 3),
    ("峰", 1), ("崖", 1), ("洞", 1), ("塔", 1), ("楼", 1), ("院", 1), ("堂", 1), ("府", 1),
    ("庄", 2), ("寨", 2), ("坊", 1), ("街", 1), ("巷", 1), ("路", 1), ("区", 2), ("馆", 1),
    ("园", 1), ("坡", 1), ("岭", 1), ("岗", 1), ("湾", 1), ("滩", 1), ("泉", 1), ("潭", 1),
    ("渊", 1), ("台", 1),
];

/// What moves someone somewhere, or says where they are.
const CUES: &[&str] = &[
    "来到", "到了", "抵达", "到达", "前往", "赶往", "去往", "赶去", "返回", "回到", "回了", "离开",
    "进入", "进了", "走进", "踏入", "踏进", "飞往", "飞向", "奔赴", "驶向", "驶入", "出了", "住进",
    "搬到", "搬进", "赶到", "赶回", "逃到", "逃往", "逃离", "途经", "路过", "来自", "出身", "位于",
    "身在", "远赴", "去了", "到", "去", "往", "在", "于", "从",
];

/// Characters a place name never holds — they end the window read after a cue.
const STOP: &str = "我你他她它您咱谁的了着过吧吗呢啊呀哦嘛么和与或及被把将向对从却便就才刚这那哪每某各\
都也又还再很更最只太是有在来去到会能要让没别个时候什怎为因所虽当随说道看想";

/// A place word with one of these before it is a common noun (这座城, 一片林).
const DETERMINER: &str = "这那一座个间片条此该每各整某几处名位";

/// Ordinals and numbers make floors and rooms (二楼, 三号院), not places.
const NUMERAL: &str = "一二三四五六七八九十百千万两零〇0123456789";

/// Place words that every book has: 大门, 医院, 山洞, 世界. Measured as the
/// candidates found in five or more of 161 books, real geography taken out.
const GENERIC: &str = include_str!("places_generic.txt");
/// Real geography: countries, provinces, cities, rivers, the old 州 and states.
/// These are places wherever they appear, suffix or not.
const GEO: &str = include_str!("places_geo.txt");

/// What follows a person's name and never a place's.
const ACTS: &[&str] = &[
    "道", "说", "笑", "问", "叹", "喝", "点头", "摇头", "皱眉", "眉头", "脸色", "目光", "嘴角",
    "心中", "身体", "身形", "冷笑", "淡淡", "微微", "轻声", "沉声", "苦笑", "怒", "闻言", "一愣",
    "大人",
];
/// What follows a rank: 斗宗强者, 斗皇巅峰.
const RANK_TAILS: &[&str] = &[
    "强者", "巅峰", "初期", "中期", "后期", "级别", "级", "阶", "之境", "境界", "高手", "实力",
    "层次", "修为", "大圆满",
];
/// Two characters that are a move and a place word: 入宫, 出山, 回村, 本村.
const MOVE_HEAD: &str = "入出回进上下本此该全满离返登过归";
const ACTS_SHARE: f32 = 0.04;
/// What follows a place: 城里, 宗内, 学院附近.
const LOCATIVES: &[&str] = &[
    "里", "中", "内", "外", "上空", "附近", "一带", "方向", "门口", "深处", "之中", "之内", "境内",
    "城外", "周围", "四周", "所在", "那边", "这边",
];
/// Before a door: 打开, 推开, 关上, 敲, 拉, 踢, 挡, 守.
const OPENS: &str = "开关推敲撞踹砸锁拉踢挡堵靠守";
/// A degree word before it makes it an adjective: 一丝淡漠, 很端庄.
const DEGREE: &str = "很些丝分得更太极颇";
/// Verbs a seed can carry on its front: 回上海, 于中国, 离楚华大学.
const GLUE_HEADS: &[&str] = &[
    "打开", "推开", "突破", "前往", "回", "离", "于", "去", "到", "在", "进", "出", "入", "开", "上",
    "下", "过", "从", "往", "向", "返", "归", "奔", "赴", "至", "抵", "飞", "逃", "住", "搬",
];
/// Common words and non-place nouns the corpus list missed.
const EXTRA_GENERIC: &[&str] = &[
    "城府", "端庄", "灭门", "辟谷", "右派", "左派", "修庙", "扫街", "辅导学院", "举国", "治国", "列国", "邦国",
    "知州", "知县", "知府", "反派", "渡河", "爬坡", "开山", "球台",
    // Factions / stances (not places)
    "保守派", "主战派", "主和派", "激进派", "温和派", "顽固派", "降临派", "拯救派", "幸存派",
    "改革派", "反对派", "学院派", "实力派", "偶像派", "演技派", "正统派", "维新派", "洋务派",
    "立宪派", "革命派",
    // Abstract worlds / domains
    "科学界", "学术界", "商界", "政界", "军界", "法界", "医界", "教育界", "演艺界", "文学界",
    "艺术界", "体育界", "新闻界", "金融界", "修炼界", "修真界", "宏观世界", "微观世界",
    "外部世界", "内部世界", "现实世界", "虚拟世界", "精神世界", "内心世界", "游戏世界",
    "异世界", "新世界", "旧世界",
    // Abstract / generic roads
    "修行路", "修仙路", "成仙路", "成神路", "长生路", "高架路", "高速路", "柏油路", "水泥路",
    "环湖公路", "盘山公路",
    // Generic buildings / rooms / objects / actions
    "整栋楼", "居民楼", "教学楼", "办公楼", "写字楼", "宿舍楼", "实验楼", "综合楼", "筒子楼",
    "老楼", "高楼", "大楼", "小楼",
    "升旗台", "领奖台", "望台", "跳台", "看台", "戏台", "擂台", "神台",
    "排水洞", "钻洞", "打洞", "挖洞", "树洞", "黑洞", "漏洞", "脑洞",
    "土坡", "高崖", "田园", "伯莱塔", "气海雪山", "积河成海", "探索遗迹", "磨砺雪山",
    "脑域", "命门", "小公园",
    "保安公司", "物流公司", "快递公司", "科技公司", "游戏公司", "影视公司", "经纪公司",
    "投资公司", "保险公司", "建筑公司", "装修公司", "物业公司",
    "安全区", "危险区", "休息区", "办公区", "生活区", "住宅区", "商业区", "工业区", "缓冲区",
];
/// Place words that end in a common word when they follow one more
/// character: 思路, 宏观, 分区, 淡漠.
const SHORT_UNSAFE: &str = "路观区漠";
const GENERIC_TAILS: &[&str] = &[
    "领域", "疆域", "区域", "地域", "值观", "生观", "界观", "景观", "上市", "开门", "推门", "参观", "之路",
    "奇观", "江湖", "平台", "讨论区", "评论区", "留言区", "豪门",
];
/// Prefixes/words that turn a trailing 门 into a physical door rather than a sect.
const DOOR_PARTS: &[&str] = &[
    "防盗", "客厅", "卧室", "卫生间", "厕所", "浴室", "厨房", "阳台", "衣柜", "柜", "房", "家",
    "商场", "卷帘", "感应", "自动", "旋转", "推拉", "折叠", "安全", "金库", "电梯", "单元",
    "楼道", "病房", "教室", "宿舍", "玻璃", "车", "舱", "店铺", "院", "校", "厂", "店",
    "大", "小", "后", "後", "前", "侧", "正", "偏", "边", "铁", "木", "石", "铜", "钢",
];
/// Common personal given names that end in a place character (e.g. 刘建国).
const PERSON_GIVEN_TAILS: &[&str] = &[
    "建国", "卫国", "振国", "兴国", "爱国", "保国", "强国", "治国", "定国", "安国", "如渊", "之渊",
];
/// Static real-world geography containment (child -> parent) used when both appear.
const GEO_PARENTS: &[(&str, &str)] = &[
    ("北京", "中国"), ("上海", "中国"), ("天津", "中国"), ("重庆", "中国"), ("香港", "中国"), ("澳门", "中国"),
    ("广州", "中国"), ("深圳", "中国"), ("杭州", "中国"), ("南京", "中国"), ("武汉", "中国"), ("成都", "中国"),
    ("西安", "中国"), ("长安", "中国"), ("洛阳", "中国"), ("济南", "中国"), ("河北", "中国"), ("河南", "中国"),
    ("山东", "中国"), ("山西", "中国"), ("广东", "中国"), ("浙江", "中国"), ("江苏", "中国"), ("四川", "中国"),
    ("湖南", "中国"), ("湖北", "中国"), ("福建", "中国"), ("陕西", "中国"), ("云南", "中国"), ("西藏", "中国"),
    ("新疆", "中国"), ("台湾", "中国"), ("江南", "中国"), ("关中", "中国"), ("中原", "中国"),
    ("大兴安岭", "中国"), ("长白山", "中国"), ("黄河", "中国"), ("长江", "中国"), ("昆仑", "中国"),
    ("纽约", "美国"), ("芝加哥", "美国"), ("华盛顿", "美国"), ("洛杉矶", "美国"), ("旧金山", "美国"),
    ("波士顿", "美国"), ("加州", "美国"), ("夏威夷", "美国"), ("阿拉斯加", "美国"), ("哈佛", "美国"),
    ("硅谷", "美国"), ("华尔街", "美国"), ("黄石国家公园", "美国"),
    ("东京", "日本"), ("东京城", "日本"), ("东京塔", "日本"), ("东京湾", "日本"), ("新宿区", "日本"),
    ("大阪", "日本"), ("京都", "日本"), ("富士山", "日本"), ("北海道", "日本"), ("函馆", "日本"),
    ("莫斯科", "俄罗斯"), ("莫斯科", "苏联"), ("圣彼得堡", "俄罗斯"), ("西伯利亚", "俄罗斯"), ("西伯利亚", "苏联"),
    ("伦敦", "英国"), ("剑桥", "英国"), ("牛津", "英国"),
    ("巴黎", "法国"),
    ("罗马", "意大利"), ("威尼斯", "意大利"), ("米兰", "意大利"), ("撒丁岛", "意大利"),
    ("柏林", "德国"), ("马德里", "西班牙"), ("首尔", "韩国"), ("曼谷", "泰国"), ("悉尼", "澳大利亚"),
];
/// A name never starts with these: 自己公司, 整条商业街, 其原.
const NOT_A_HEAD: &[&str] = &["自己", "整条", "整座", "整个", "其"];
/// Single-character place words that also end given names: 谭青山, 韩重山,
/// 龙清泉. A surname-led name of this shape must be followed by a locative
/// now and then, or it is a person.
const NAME_TAILS: &str = "山峰林海泉堂江河国城崖湖岭石原观";
/// Surnames the cast list leaves out, seen leading such names.
const MORE_SURNAMES: &str = "瞿靳曲屈";
const LOCATED_SHARE: f32 = 0.08;
/// …unless it is gone to and stood in often enough: 夏海 is a city.
const SEEDED_SHARE: f32 = 0.15;
const RANK_SHARE: f32 = 0.15;

const MAX_LEN: usize = 8;
const MIN_MENTIONS: u32 = 8;
const MIN_CHAPTERS: u32 = 2;
const MIN_SEEDED: u32 = 2;
/// One character after the name taking this share of its mentions means the
/// name is the front of a longer word (魂殿殿|主, 胡大学|士, 斗宗|强者).
const WELDED_RIGHT: f32 = 0.5;
const MAX_DETERMINED: f32 = 0.15;
pub const MAX_PLACES: usize = 60;
/// Bumped whenever the rules change, so a cached atlas from older rules is
/// built again rather than served.
pub const PLACE_VERSION: u32 = 2;

fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}

fn is_physical_door(name: &str) -> bool {
    let Some(stem) = name.strip_suffix('门') else {
        return false;
    };
    DOOR_PARTS.iter().any(|p| stem == *p || stem.ends_with(p))
}

/// Build real-world geography rank table from `places_geo.txt`:
/// line 0: continents (6) & countries (5)
/// line 1: provinces / direct municipalities / macro regions (4)
/// line 2: cities & historical capitals (3)
/// line 3: historical prefectures/zhou (4)
/// line 4: historical dynasties/states (5)
/// line 5: rivers/mountains/foreign cities/landmarks (suffix or city=3/region=4/2)
fn parse_geo() -> HashMap<&'static str, u8> {
    const CONTINENTS: &[&str] = &[
        "欧洲", "亚洲", "非洲", "美洲", "北美", "南美", "大洋洲", "南极", "北极",
    ];
    const FOREIGN_REGIONS: &[&str] = &[
        "加州", "夏威夷", "阿拉斯加", "德克萨斯", "佛罗里达", "西伯利亚",
    ];
    const FOREIGN_CITIES: &[&str] = &[
        "纽约", "伦敦", "巴黎", "柏林", "罗马", "莫斯科", "首尔", "大阪", "京都", "曼谷", "悉尼",
        "洛杉矶", "旧金山", "芝加哥", "华盛顿", "波士顿", "拉斯维加斯", "维也纳", "威尼斯", "米兰",
        "马德里", "巴塞罗那", "阿姆斯特丹", "布鲁塞尔", "日内瓦", "苏黎世", "圣彼得堡", "开罗",
        "迪拜", "孟买", "新德里", "吉隆坡", "雅加达", "马尼拉", "河内", "西贡", "仰光",
    ];
    let mut map = HashMap::new();
    for (line_idx, line) in GEO.lines().enumerate() {
        for word in line.split_whitespace() {
            let r = match line_idx {
                0 => {
                    if CONTINENTS.contains(&word) { 6 } else { 5 }
                }
                1 | 3 => 4,
                2 => 3,
                4 => 5,
                _ => {
                    if FOREIGN_REGIONS.contains(&word) {
                        4
                    } else if FOREIGN_CITIES.contains(&word) {
                        3
                    } else {
                        2
                    }
                }
            };
            map.entry(word).or_insert(r);
        }
    }
    map
}

fn suffix_tables() -> &'static (HashMap<char, Vec<(&'static str, u8)>>, HashMap<char, u8>) {
    static TBL: std::sync::OnceLock<(HashMap<char, Vec<(&'static str, u8)>>, HashMap<char, u8>)> =
        std::sync::OnceLock::new();
    TBL.get_or_init(|| {
        let mut long_by_last: HashMap<char, Vec<(&'static str, u8)>> = HashMap::new();
        for &(w, r) in SUFFIX_LONG {
            if let Some(last) = w.chars().last() {
                long_by_last.entry(last).or_default().push((w, r));
            }
        }
        let mut one_map: HashMap<char, u8> = HashMap::with_capacity(SUFFIX_ONE.len());
        for &(w, r) in SUFFIX_ONE {
            if let Some(c) = w.chars().next() {
                one_map.entry(c).or_insert(r);
            }
        }
        (long_by_last, one_map)
    })
}

fn rank(s: &str, geo: &HashMap<&str, u8>) -> Option<u8> {
    if let Some(&r) = geo.get(s) {
        return Some(r);
    }
    let last = s.chars().last()?;
    let (long_by_last, one_map) = suffix_tables();
    if let Some(cands) = long_by_last.get(&last) {
        for &(w, r) in cands {
            if s.len() > w.len() && s.ends_with(w) {
                return Some(r);
            }
        }
    }
    if let Some(&r) = one_map.get(&last) {
        if s.len() > last.len_utf8() {
            return Some(r);
        }
    }
    None
}

#[derive(Default, Clone, Debug)]
pub struct Stat {
    pub seeded: u32,
    pub count: u32,
    pub chapters: u32,
    pub determined: u32,
    pub lefts: u32,
    pub right_top: u32,
    /// Followed by what a person does (道、笑、点头…): a name, not a place.
    pub acts: u32,
    /// Followed by what a rank takes (强者、巅峰、初期…): 斗宗 is reached, not visited.
    pub ranked: u32,
    /// Followed by a locative (里、中、附近…): what a place takes.
    pub located: u32,
    /// After 打开、推开、关上: a door, not a sect.
    pub opened: u32,
    pub first_chapter: usize,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Place {
    pub name: String,
    pub mentions: u32,
    pub chapters: u32,
    pub first_chapter: usize,
    pub rank: u8,
    /// Index into [`Atlas::places`] of the place this one is named inside.
    pub parent: Option<usize>,
    /// Chapters this place is where the story is.
    pub settings: u32,
    /// Cast members seen most in the chapters set here.
    pub people: Vec<(String, u32)>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Trip {
    pub from: usize,
    pub to: usize,
    pub count: u32,
    /// First chapter the trip is made in.
    pub first: usize,
}

/// A run of chapters spent in one area — one "map" of the book.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Stage {
    pub from: usize,
    pub to: usize,
    pub area: usize,
    /// Places the story stood in during this stage, by chapters.
    pub spots: Vec<(usize, u32)>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, Default)]
pub struct Atlas {
    pub places: Vec<Place>,
    pub trips: Vec<Trip>,
    pub stages: Vec<Stage>,
    /// Per chapter: where it is set, if anywhere could be told.
    pub setting: Vec<Option<usize>>,
}

fn paragraphs<'a>(text: &'a str, chapters: &[Chapter], n: usize) -> Vec<(usize, &'a str)> {
    let mut paras = Vec::new();
    for ch in chapters.iter().take(n) {
        for line in text[ch.body_start..ch.span.end].split('\n') {
            let line = line.trim();
            if !line.is_empty() {
                paras.push((ch.index, line));
            }
        }
    }
    paras
}

/// Every suffix-ending run read after a cue, with how often it was read so,
/// per chapter.
fn seeds(paras: &[(usize, &str)], geo: &HashMap<&str, u8>) -> HashMap<String, HashMap<usize, u32>> {
    let mut cues_by_head: HashMap<char, Vec<Vec<char>>> = HashMap::new();
    for c in CUES {
        let v: Vec<char> = c.chars().collect();
        cues_by_head.entry(v[0]).or_default().push(v);
    }
    let mut out: HashMap<String, HashMap<usize, u32>> = HashMap::new();
    let mut idx: Vec<(usize, char)> = Vec::with_capacity(256);
    for (ch, p) in paras {
        idx.clear();
        idx.extend(p.char_indices());
        let n = idx.len();
        for i in 0..n {
            let Some(cands) = cues_by_head.get(&idx[i].1) else {
                continue;
            };
            let Some(cue) = cands.iter().find(|c| {
                i + c.len() <= n && c.iter().enumerate().all(|(m, &cc)| idx[i + m].1 == cc)
            }) else {
                continue;
            };
            let mut j = i + cue.len();
            if j < n && matches!(idx[j].1, '了' | '过') {
                j += 1;
            }
            if j >= n {
                continue;
            }
            let start_b = idx[j].0;
            let mut k = j;
            while k < n && k - j < MAX_LEN {
                let c = idx[k].1;
                if !is_cjk(c) || STOP.contains(c) {
                    break;
                }
                k += 1;
                if k - j >= 2 {
                    let end_b = if k == n { p.len() } else { idx[k].0 };
                    let s = &p[start_b..end_b];
                    if rank(s, geo).is_some() {
                        if let Some(m) = out.get_mut(s) {
                            *m.entry(*ch).or_default() += 1;
                        } else {
                            let mut m = HashMap::new();
                            m.insert(*ch, 1);
                            out.insert(s.to_string(), m);
                        }
                    }
                }
            }
        }
    }
    out
}

#[derive(Default)]
struct FastU32Hasher(u64);
impl std::hash::Hasher for FastU32Hasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ (b as u64)).wrapping_mul(0x517cc1b727220a95);
        }
    }
    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.0 = (i as u64).wrapping_mul(0x517cc1b727220a95);
    }
}
type FastU32Map<V> = HashMap<u32, V, std::hash::BuildHasherDefault<FastU32Hasher>>;

#[inline]
fn pack_pair(a: char, b: char) -> u32 {
    ((a as u32) << 16) | (b as u32 & 0xffff)
}

#[inline]
fn bmp_set(bits: &mut [u64; 1024], c: char) {
    let u = c as u32;
    if u < 65536 {
        bits[(u >> 6) as usize] |= 1u64 << (u & 63);
    }
}

#[inline]
fn bmp_has(bits: &[u64; 1024], c: char) -> bool {
    let u = c as u32;
    u < 65536 && (bits[(u >> 6) as usize] & (1u64 << (u & 63))) != 0
}

fn raw_stats(
    paras: &[(usize, &str)],
    names: &HashSet<String>,
) -> HashMap<String, Stat> {
    let name_vec: Vec<String> = names.iter().cloned().collect();
    let n_names = name_vec.len();
    let mut stats: Vec<Stat> = (0..n_names)
        .map(|_| Stat { first_chapter: usize::MAX, ..Default::default() })
        .collect();
    let mut last_ch: Vec<usize> = vec![usize::MAX; n_names];
    let mut lefts: Vec<HashSet<char>> = (0..n_names).map(|_| HashSet::new()).collect();
    let mut rights: Vec<HashMap<char, u32>> = (0..n_names).map(|_| HashMap::new()).collect();

    // Index all candidate names by their first two chars + 8KB L1 head bitmap.
    let mut head_bmp = [0u64; 1024];
    let mut by_pair: FastU32Map<Vec<(usize, usize)>> = FastU32Map::default();
    for (id, name) in name_vec.iter().enumerate() {
        let mut it = name.chars();
        if let (Some(c0), Some(c1)) = (it.next(), it.next()) {
            bmp_set(&mut head_bmp, c0);
            let char_len = 2 + it.count();
            by_pair.entry(pack_pair(c0, c1)).or_default().push((id, char_len));
        }
    }

    let mut idx: Vec<(usize, char)> = Vec::with_capacity(256);
    for (ch, p) in paras {
        idx.clear();
        idx.extend(p.char_indices());
        let n = idx.len();
        if n < 2 {
            continue;
        }
        for a in 0..(n - 1) {
            let c0 = idx[a].1;
            if !bmp_has(&head_bmp, c0) {
                continue;
            }
            let Some(cands) = by_pair.get(&pack_pair(c0, idx[a + 1].1)) else {
                continue;
            };
            let start_b = idx[a].0;
            let tail = &p[start_b..];
            for &(id, char_len) in cands {
                let w = name_vec[id].as_str();
                if a + char_len > n || !tail.starts_with(w) {
                    continue;
                }
                let e = &mut stats[id];
                e.count += 1;
                let left = if a > 0 { idx[a - 1].1 } else { '^' };
                if DETERMINER.contains(left) {
                    e.determined += 1;
                }
                if last_ch[id] != *ch {
                    last_ch[id] = *ch;
                    e.chapters += 1;
                    e.first_chapter = e.first_chapter.min(*ch);
                }
                lefts[id].insert(left);
                let rest = &tail[w.len()..];
                if ACTS.iter().any(|aw| rest.starts_with(aw)) {
                    e.acts += 1;
                }
                if RANK_TAILS.iter().any(|rw| rest.starts_with(rw)) {
                    e.ranked += 1;
                }
                if LOCATIVES.iter().any(|lw| rest.starts_with(lw)) {
                    e.located += 1;
                }
                if OPENS.contains(left) {
                    e.opened += 1;
                }
                if DEGREE.contains(left) {
                    e.determined += 1;
                }
                if a + char_len < n {
                    *rights[id].entry(idx[a + char_len].1).or_default() += 1;
                }
            }
        }
    }
    let mut out = HashMap::with_capacity(n_names);
    for (id, mut st) in stats.into_iter().enumerate() {
        st.lefts = lefts[id].len() as u32;
        st.right_top = rights[id].values().max().copied().unwrap_or(0);
        out.insert(name_vec[id].clone(), st);
    }
    out
}

/// Diagnostic: every seeded candidate with its raw counts.
pub fn candidate_stats(text: &str, chapters: &[Chapter], upto: usize) -> Vec<(String, Stat)> {
    let geo = parse_geo();
    let paras = paragraphs(text, chapters, upto.min(chapters.len()));
    let seeded = seeds(&paras, &geo);
    let names: HashSet<String> = seeded.keys().cloned().collect();
    let mut stats = raw_stats(&paras, &names);
    for (k, v) in &seeded {
        stats.get_mut(k).unwrap().seeded = v.values().sum();
    }
    let mut out: Vec<(String, Stat)> = stats.into_iter().collect();
    out.sort_by(|a, b| b.1.count.cmp(&a.1.count));
    out
}

/// Why a candidate was turned away, or None when it is a place.
pub fn reject(name: &str, st: &Stat, people: &[String], generic: &HashSet<&str>, geo: &HashMap<&str, u8>) -> Option<&'static str> {
    let is_geo = geo.contains_key(name);
    let len = name.chars().count();
    let head = name.chars().next().unwrap_or(' ');
    let tail = &name[head.len_utf8()..];
    if !is_geo {
        if generic.contains(name) || EXTRA_GENERIC.contains(&name) || GENERIC_TAILS.iter().any(|t| name.ends_with(t)) {
            return Some("常见词");
        }
        if is_physical_door(name) {
            return Some("门");
        }
        if len == 2 && head == '阿' {
            return Some("人名");
        }
        if (len == 3 || len == 4)
            && (crate::cast::SURNAMES.contains(head) || MORE_SURNAMES.contains(head) || crate::cast::COMPOUND_SURNAMES.iter().any(|c| name.starts_with(c)))
            && PERSON_GIVEN_TAILS.iter().any(|t| name.ends_with(t))
        {
            return Some("人名");
        }
        if len == 2 && SHORT_UNSAFE.contains(tail) && !"东西南北".contains(head) {
            return Some("常见词");
        }
        if name.chars().any(|c| NUMERAL.contains(c)) {
            return Some("数字");
        }
        if NOT_A_HEAD.iter().any(|h| name.starts_with(h)) {
            return Some("常见词");
        }
        if len == 2 && name.chars().all(|c| SUFFIX_ONE.iter().any(|(w, _)| w.starts_with(c))) {
            return Some("常见词");
        }
        if let Some((_, rest)) = name.split_once('开') {
            if SUFFIX_LONG.iter().any(|(w, _)| *w == rest) || generic.contains(rest) {
                return Some("动词");
            }
        }
        if CUES.iter().any(|c| c.chars().count() >= 2 && name.starts_with(c))
            || (MOVE_HEAD.contains(head)
                && (tail.chars().count() == 1
                    || generic.contains(tail)
                    || SUFFIX_LONG.iter().any(|(w, _)| *w == tail)))
        {
            return Some("动词");
        }
        if RANK_TAILS.iter().any(|w| name.ends_with(w)) {
            return Some("境界");
        }
    }
    if people.iter().any(|p| p == name || p.contains(name) || name.contains(p.as_str())) {
        return Some("人名");
    }
    if is_geo {
        return None;
    }
    if st.count < MIN_MENTIONS || st.chapters < MIN_CHAPTERS || st.seeded < MIN_SEEDED {
        return Some("太少");
    }
    if st.right_top as f32 > st.count as f32 * WELDED_RIGHT {
        return Some("粘右");
    }
    if st.determined as f32 > st.count as f32 * MAX_DETERMINED {
        return Some("泛指");
    }
    if st.acts as f32 > st.count as f32 * ACTS_SHARE {
        return Some("像人");
    }
    let compound = crate::cast::COMPOUND_SURNAMES.iter().any(|c| name.starts_with(c));
    if ((len == 2 || len == 3) && (crate::cast::SURNAMES.contains(head) || MORE_SURNAMES.contains(head))
        || len == 4 && compound)
        && name.chars().last().is_some_and(|c| NAME_TAILS.contains(c))
        && (st.located as f32) < st.count as f32 * LOCATED_SHARE
        && (st.seeded as f32) < st.count as f32 * SEEDED_SHARE
    {
        return Some("像人");
    }
    if st.ranked as f32 > st.count as f32 * RANK_SHARE {
        return Some("境界");
    }
    if name.ends_with('门') && st.opened as f32 > st.count as f32 * 0.06 {
        return Some("门");
    }
    None
}

/// A seed with a verb still on its front (回上海) when the rest is a seed of
/// its own said at least twice as often.
fn glued(name: &str, stats: &HashMap<String, Stat>) -> bool {
    let me = stats.get(name).map_or(0, |s| s.count);
    GLUE_HEADS.iter().any(|h| {
        name.strip_prefix(h)
            .filter(|rest| rest.chars().count() >= 2)
            .and_then(|rest| stats.get(rest))
            .is_some_and(|s| s.count >= 2 * me)
    })
}

pub fn scan(text: &str, chapters: &[Chapter], upto: usize) -> Atlas {
    let n = upto.min(chapters.len());
    let ranked: Vec<(String, Vec<String>)> = crate::cast::scan_ranked(text, chapters, n)
        .into_iter()
        .map(|p| (p.name, p.aliases))
        .collect();
    scan_ranked(text, chapters, n, &ranked)
}

/// How many of the cast are looked for in the chapters set at each place.
const LEADS: usize = 20;

/// [`scan`], given the cast's ranked people (name and aliases, most mentioned
/// first) — as a cached [`crate::cast::Cast`] keeps them — so the cast is not
/// scanned a second time.
pub fn scan_ranked(text: &str, chapters: &[Chapter], upto: usize, ranked: &[(String, Vec<String>)]) -> Atlas {
    scan_without(text, chapters, upto, ranked, &[])
}

/// [`scan_ranked`], excluding any place names the reader removed by hand.
pub fn scan_without(
    text: &str,
    chapters: &[Chapter],
    upto: usize,
    ranked: &[(String, Vec<String>)],
    removed: &[String],
) -> Atlas {
    let n = upto.min(chapters.len());
    let people: Vec<String> = ranked
        .iter()
        .flat_map(|(name, aliases)| std::iter::once(name.clone()).chain(aliases.iter().cloned()))
        .filter(|s| s.chars().count() >= 2)
        .collect();
    let leads: Vec<String> = ranked.iter().take(LEADS).map(|(name, _)| name.clone()).collect();
    scan_with(text, chapters, n, &people, &leads, removed)
}

pub fn scan_with(
    text: &str,
    chapters: &[Chapter],
    n: usize,
    people: &[String],
    leads: &[String],
    removed: &[String],
) -> Atlas {
    let geo = parse_geo();
    let generic: HashSet<&str> = GENERIC.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let removed_set: HashSet<&str> = removed.iter().map(String::as_str).collect();
    let paras = paragraphs(text, chapters, n);
    let seeded = seeds(&paras, &geo);
    let names: HashSet<String> = seeded.keys().cloned().collect();
    let mut stats = raw_stats(&paras, &names);
    for (k, v) in &seeded {
        stats.get_mut(k).unwrap().seeded = v.values().sum();
    }
    if std::env::var("PLACE_RAW").is_ok() {
        let mut all: Vec<(&String, &Stat)> = stats.iter().filter(|(_, v)| v.seeded >= 2 && v.count >= 8).collect();
        all.sort_by(|a, b| b.1.count.cmp(&a.1.count));
        for (k, v) in all.iter().take(150) {
            let why = if removed_set.contains(k.as_str()) {
                Some("手动移除")
            } else if glued(k, &stats) {
                Some("粘动词")
            } else {
                reject(k, v, people, &generic, &geo)
            };
            eprintln!(
                "{:<8} {:>5} 引{:>4} 限{:>3} 人{:>3} 位{:>3} 开{:>3} {}",
                k, v.count, v.seeded, v.determined, v.acts, v.located, v.opened, why.unwrap_or("✓")
            );
        }
    }
    let glue: HashSet<String> = stats.keys().filter(|k| glued(k, &stats)).cloned().collect();
    let mut kept: Vec<(String, Stat)> = stats
        .into_iter()
        .filter(|(k, v)| {
            !removed_set.contains(k.as_str())
                && !glue.contains(k)
                && reject(k, v, people, &generic, &geo).is_none()
        })
        .collect();
    kept.sort_by(|a, b| b.1.count.cmp(&a.1.count).then(a.0.cmp(&b.0)));

    // Own mentions: a mention inside a longer kept name is that name's
    // (黄原 inside 黄原城), read greedily left to right.
    let mut own = vec![0u32; kept.len()];
    let mut per_ch: Vec<HashMap<usize, u32>> = vec![HashMap::new(); kept.len()];
    let mut chs: Vec<HashSet<usize>> = vec![HashSet::new(); kept.len()];
    // (outer, inner) adjacent pairs: 云岚宗后山, 加玛帝国的帝都.
    let mut pairs: HashMap<(usize, usize), u32> = HashMap::new();
    let mut ch_people: Vec<HashMap<usize, u32>> = vec![HashMap::new(); n.max(1)];
    // Index kept places by first 2 chars + 8KB L1 head bitmap, sorted longest-first.
    let mut head_bmp = [0u64; 1024];
    let mut by_pair: FastU32Map<Vec<(usize, usize)>> = FastU32Map::default();
    for (i, (k, _)) in kept.iter().enumerate() {
        let mut it = k.chars();
        if let (Some(c0), Some(c1)) = (it.next(), it.next()) {
            bmp_set(&mut head_bmp, c0);
            let char_len = 2 + it.count();
            by_pair.entry(pack_pair(c0, c1)).or_default().push((i, char_len));
        }
    }
    for v in by_pair.values_mut() {
        v.sort_by(|a, b| b.1.cmp(&a.1));
    }
    let mut idx: Vec<(usize, char)> = Vec::with_capacity(256);
    for (ch, p) in &paras {
        idx.clear();
        idx.extend(p.char_indices());
        let len_p = idx.len();
        let mut a = 0;
        let mut prev: Option<(usize, usize)> = None; // (place, end byte offset)
        while a + 1 < len_p {
            let mut hit = None;
            let c0 = idx[a].1;
            if bmp_has(&head_bmp, c0) {
                if let Some(cands) = by_pair.get(&pack_pair(c0, idx[a + 1].1)) {
                    let tail = &p[idx[a].0..];
                    for &(i, clen) in cands {
                        let name = kept[i].0.as_str();
                        if a + clen <= len_p && tail.starts_with(name) {
                            hit = Some((i, clen, idx[a].0 + name.len()));
                            break;
                        }
                    }
                }
            }
            if let Some((i, clen, end_b)) = hit {
                own[i] += 1;
                *per_ch[i].entry(*ch).or_default() += 1;
                chs[i].insert(*ch);
                if let Some((pi, pend_b)) = prev {
                    let gap = &p[pend_b..idx[a].0];
                    if pi != i
                        && matches!(
                            gap,
                            "" | "的" | "之" | "中的" | "内的" | "里的" | "之中的"
                                | "境内" | "境内的" | "一带" | "一带的" | "附近" | "附近的"
                                | "城内" | "城内的" | "城外" | "城外的" | "中心" | "中心的"
                                | "深处" | "深处的"
                        )
                    {
                        *pairs.entry((pi, i)).or_default() += 1;
                    }
                }
                prev = Some((i, end_b));
                a += clen;
            } else {
                a += 1;
            }
        }
        for (pi, lead) in leads.iter().enumerate() {
            if p.contains(lead.as_str()) {
                *ch_people[*ch].entry(pi).or_default() += 1;
            }
        }
    }
    let geo_rank = |s: &str| rank(s, &geo).unwrap_or(1);
    let mut order: Vec<usize> = (0..kept.len())
        .filter(|&i| own[i] >= MIN_MENTIONS && chs[i].len() as u32 >= MIN_CHAPTERS)
        .collect();
    order.sort_by(|&a, &b| own[b].cmp(&own[a]));
    order.truncate(MAX_PLACES);
    let mut places: Vec<Place> = order
        .iter()
        .map(|&i| Place {
            name: kept[i].0.clone(),
            mentions: own[i],
            chapters: chs[i].len() as u32,
            first_chapter: chs[i].iter().min().copied().unwrap_or(0),
            rank: geo_rank(&kept[i].0),
            parent: None,
            settings: 0,
            people: Vec::new(),
        })
        .collect();

    // Belonging: named inside another at least twice, and the outer one is
    // the bigger kind of place, or the inner name starts with the outer one,
    // or a known real-world geographic parent is present in the book.
    for (j, pl) in places.clone().iter().enumerate() {
        let mut best: Option<(usize, u32)> = None;
        for (k, outer) in places.iter().enumerate() {
            if k == j {
                continue;
            }
            let named_in = pl.name.starts_with(outer.name.as_str()) && pl.name.len() > outer.name.len();
            let geo_in = GEO_PARENTS
                .iter()
                .any(|&(child, parent)| child == pl.name && parent == outer.name);
            let c = pairs.get(&(order[k], order[j])).copied().unwrap_or(0);
            let ok = named_in || geo_in || (c >= 2 && outer.rank > pl.rank);
            let score = if named_in {
                c + 1000
            } else if geo_in {
                c + 500
            } else {
                c
            };
            if ok && best.is_none_or(|(_, s)| score > s) {
                best = Some((k, score));
            }
        }
        places[j].parent = best.map(|b| b.0);
    }
    // No cycles: a parent chain that comes back drops its last link.
    for j in 0..places.len() {
        let mut seen = HashSet::new();
        let mut at = j;
        while let Some(p) = places[at].parent {
            if !seen.insert(at) {
                places[at].parent = None;
                break;
            }
            at = p;
        }
    }

    // Setting per chapter: the place mentioned most, a cue mention counting
    // three; under three points the story stays where it was.
    let mut setting: Vec<Option<usize>> = vec![None; n];
    let mut current = None;
    for c in 0..n {
        let mut best: Option<(usize, u32)> = None;
        for (new, &old) in order.iter().enumerate() {
            if places[new].rank >= 5 {
                continue;
            }
            let m = per_ch[old].get(&c).copied().unwrap_or(0);
            if m == 0 {
                continue;
            }
            let cue = seeded.get(&kept[old].0).and_then(|s| s.get(&c)).copied().unwrap_or(0);
            let score = m + 2 * cue;
            if best.is_none_or(|(_, s)| score > s) {
                best = Some((new, score));
            }
        }
        if let Some((p, s)) = best {
            if s >= 3 {
                current = Some(p);
            }
        }
        setting[c] = current;
    }
    for c in 0..n {
        if let Some(p) = setting[c] {
            places[p].settings += 1;
        }
    }

    // Trips: the setting changing from one place to another.
    let mut trips: HashMap<(usize, usize), (u32, usize)> = HashMap::new();
    let mut last = None;
    for (c, s) in setting.iter().enumerate() {
        if let Some(p) = *s {
            if let Some(q) = last {
                if q != p {
                    let e = trips.entry((q, p)).or_insert((0, c));
                    e.0 += 1;
                }
            }
            last = Some(p);
        }
    }
    let mut trips: Vec<Trip> = trips
        .into_iter()
        .map(|((from, to), (count, first))| Trip { from, to, count, first })
        .collect();
    trips.sort_by(|a, b| a.first.cmp(&b.first));

    // People: who is around in the chapters set in each place.
    for (p, pl) in places.iter_mut().enumerate() {
        let mut tally: HashMap<usize, u32> = HashMap::new();
        for c in 0..n {
            if setting[c] == Some(p) {
                for (who, k) in &ch_people[c] {
                    *tally.entry(*who).or_default() += k;
                }
            }
        }
        // Ties go to the higher-ranked lead, so a rescan says the same.
        let mut v: Vec<(usize, u32)> = tally.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v.truncate(5);
        pl.people = v.into_iter().map(|(w, k)| (leads[w].clone(), k)).collect();
    }

    let counts: Vec<Vec<u32>> = order
        .iter()
        .map(|&old| (0..n).map(|c| per_ch[old].get(&c).copied().unwrap_or(0)).collect())
        .collect();
    let stages = stages(&counts, &setting, n);
    Atlas { places, trips, stages, setting }
}

/// Stages: where the book changes maps. Places do not share sentences the way
/// people do; what a map change looks like instead is the whole mix of place
/// names turning over — the old ones stop being said and new ones take over.
/// So a cut is put where the mentions in the chapters before a point look
/// least like those after it (TextTiling, run on place names): the window is
/// a fraction of the book, and cuts are kept a window apart.
const STAGE_WINDOWS: usize = 25;
const MIN_WINDOW: usize = 4;
const MAX_WINDOW: usize = 40;
/// Below this cosine between the two sides, the map has changed.
const CUT_SIMILARITY: f32 = 0.35;

fn stages(counts: &[Vec<u32>], setting: &[Option<usize>], n: usize) -> Vec<Stage> {
    let w = (n / STAGE_WINDOWS).clamp(MIN_WINDOW, MAX_WINDOW);
    let k = counts.len();
    if k == 0 || n == 0 {
        return Vec::new();
    }
    // Damped so one place said fifty times in a chapter does not drown the
    // rest, and weighted by how few chapters say it at all: the place a book
    // never leaves (庆国, 监察院) says nothing about where a map ends.
    let idf: Vec<f32> = counts
        .iter()
        .map(|row| {
            let present = row.iter().filter(|&&m| m > 0).count().max(1);
            (n as f32 / present as f32).ln()
        })
        .collect();
    let v = |c: usize, p: usize| (counts[p][c] as f32).sqrt() * idf[p];
    let mut prefix = vec![vec![0f32; k]; n + 1];
    for c in 0..n {
        for p in 0..k {
            prefix[c + 1][p] = prefix[c][p] + v(c, p);
        }
    }
    let side = |a: usize, b: usize| -> Vec<f32> { (0..k).map(|p| prefix[b][p] - prefix[a][p]).collect() };
    let cos = |x: &[f32], y: &[f32]| {
        let d: f32 = x.iter().zip(y).map(|(a, b)| a * b).sum();
        let nx: f32 = x.iter().map(|a| a * a).sum::<f32>().sqrt();
        let ny: f32 = y.iter().map(|a| a * a).sum::<f32>().sqrt();
        if nx == 0.0 || ny == 0.0 { 1.0 } else { d / (nx * ny) }
    };
    let mut gaps: Vec<(usize, f32)> = Vec::new();
    if n >= 2 * w {
        for b in w..=n - w {
            gaps.push((b, cos(&side(b - w, b), &side(b, b + w))));
        }
    }
    gaps.sort_by(|a, b| a.1.total_cmp(&b.1));
    let mut cuts: Vec<usize> = Vec::new();
    for (b, sim) in gaps {
        if sim >= CUT_SIMILARITY {
            break;
        }
        if cuts.iter().all(|&c| c.abs_diff(b) >= w) {
            cuts.push(b);
        }
    }
    cuts.sort();
    let mut bounds = vec![0];
    bounds.extend(cuts);
    bounds.push(n);
    bounds
        .windows(2)
        .map(|r| {
            let (from, to) = (r[0], r[1]);
            // Named by what is said most here and least elsewhere.
            let mut score: Vec<(usize, f32, u32)> = (0..k)
                .map(|p| {
                    let here: u32 = counts[p][from..to].iter().sum();
                    let all: u32 = counts[p].iter().sum();
                    (p, here as f32 * here as f32 / all.max(1) as f32, here)
                })
                .filter(|x| x.2 > 0)
                .collect();
            score.sort_by(|a, b| b.1.total_cmp(&a.1));
            let spots: Vec<(usize, u32)> = score.iter().take(6).map(|x| (x.0, x.2)).collect();
            let mut tally: HashMap<usize, u32> = HashMap::new();
            for s in setting[from..to].iter().flatten() {
                *tally.entry(*s).or_default() += 1;
            }
            let area = spots.first().map(|x| x.0).unwrap_or(0);
            Stage { from, to: to - 1, area, spots }
        })
        .collect()
}
