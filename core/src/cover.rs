//! What a cover could show, read off the book's title.
//!
//! The cover model (`app/rust/src/api/image.rs`) takes English tags. It draws
//! concrete, visible things well: one person's clothes and what they hold, a
//! place, the time and the weather, a few objects. It ignores Chinese, and it
//! cannot draw a plot or who does what to whom. So a title is read against a
//! fixed vocabulary of Chinese cue words, each tied to English tags: 剑来 draws
//! a sword, 龙族 a dragon, 冬日重现 snow. The book's genre tags pick the rest
//! of the scene. Nothing here writes a prompt freehand.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// What the lead is (世子, 剑客, 学生). It sets their clothes.
    Role,
    /// How the lead looks: hair, eyes, a coloured robe, glasses.
    Look,
    /// What the lead holds.
    Item,
    /// Where the cover is set.
    Place,
    /// The time of day and the weather.
    Sky,
    /// Something in the scene: blossoms, lanterns, a fox.
    Motif,
}

#[derive(Debug)]
pub struct Word {
    pub kind: Kind,
    /// The key the app sends back.
    pub label: &'static str,
    /// Words in a title that mean this.
    pub triggers: &'static [&'static str],
    /// What the cover model is told.
    pub tags: &'static str,
}

const fn w(
    kind: Kind,
    label: &'static str,
    triggers: &'static [&'static str],
    tags: &'static str,
) -> Word {
    Word {
        kind,
        label,
        triggers,
        tags,
    }
}

use Kind::*;

pub const VOCABULARY: &[Word] = &[
    // Roles. Clothes follow from what someone is.
    w(Role, "世子", &["世子", "小王爷", "王爷", "皇子", "太子", "王子"], "hanfu, noble, hair ornament"),
    w(Role, "公主", &["公主", "郡主"], "hanfu, princess, hair ornament"),
    w(Role, "公子", &["公子", "少爷", "少主"], "hanfu, noble"),
    w(Role, "剑客", &["剑客", "剑修", "剑仙", "剑侠", "侠客", "剑士", "少侠"], "swordsman, hanfu"),
    w(Role, "道士", &["道士", "道长", "道人", "天师", "道童"], "taoist robe"),
    w(Role, "僧人", &["和尚", "僧人", "高僧", "小和尚"], "monk, bald, kasaya"),
    w(Role, "书生", &["书生", "秀才", "读书人"], "scholar, hanfu"),
    w(Role, "将军", &["将军", "武将", "统领", "将领"], "armor, general"),
    w(Role, "修士", &["修士", "修仙者", "炼气士", "仙人"], "taoist robe, flowing robes"),
    w(Role, "学生", &["学生", "高中生", "大学生", "初中生", "新生"], "school uniform"),
    w(Role, "侦探", &["侦探", "探长", "值夜者"], "detective, trench coat"),
    w(Role, "警察", &["警察", "警官", "刑警", "巡警"], "police uniform"),
    w(Role, "医生", &["医生", "外科医生", "法医"], "doctor, lab coat"),
    w(Role, "杀手", &["杀手", "刺客"], "assassin, black clothes, hood"),
    w(Role, "骑士", &["骑士"], "knight, armor"),
    w(Role, "法师", &["法师", "魔法师", "巫师", "术士", "魔导师"], "mage, robe"),
    w(Role, "军人", &["军人", "士兵", "军官", "特种兵"], "military uniform"),
    w(Role, "偶像", &["偶像", "明星", "歌手", "主播"], "idol, stage costume"),
    w(Role, "女仆", &["女仆"], "maid, maid headdress"),
    w(Role, "巫女", &["巫女"], "miko"),
    // Looks.
    w(Look, "黑发", &["黑发", "乌发", "黑色头发", "黑色的头发"], "black hair"),
    w(Look, "白发", &["白发", "白头发", "雪发"], "white hair"),
    w(Look, "银发", &["银发", "银白色的头发", "银色头发", "银色的头发"], "silver hair"),
    w(Look, "金发", &["金发", "金色头发", "金色的头发"], "blonde hair"),
    w(Look, "红发", &["红发", "赤发", "红色头发", "红色的头发"], "red hair"),
    w(Look, "蓝发", &["蓝发", "蓝色头发", "蓝色的头发"], "blue hair"),
    w(Look, "紫发", &["紫发", "紫色头发", "紫色的头发"], "purple hair"),
    w(Look, "粉发", &["粉发", "粉色头发", "粉色的头发"], "pink hair"),
    w(Look, "棕发", &["棕发", "棕色头发", "棕色的头发", "栗色头发"], "brown hair"),
    w(Look, "长发", &["长发", "长头发"], "long hair"),
    w(Look, "短发", &["短发", "短头发"], "short hair"),
    w(Look, "马尾", &["马尾", "马尾辫"], "ponytail"),
    w(Look, "双马尾", &["双马尾"], "twintails"),
    w(Look, "红瞳", &["红瞳", "红眸", "赤瞳", "血瞳", "红色的眸", "红色眼"], "red eyes"),
    w(Look, "金瞳", &["金瞳", "金眸", "黄金瞳", "金色的瞳", "金色的眼", "金色眼"], "golden eyes, glowing eyes"),
    w(Look, "蓝眸", &["蓝眸", "蓝瞳", "碧眼", "蓝色的眼", "蓝色眼"], "blue eyes"),
    w(Look, "绿瞳", &["绿瞳", "绿眸", "碧眸", "绿色的眼", "绿色眼"], "green eyes"),
    w(Look, "紫瞳", &["紫瞳", "紫眸", "紫色的眼"], "purple eyes"),
    w(Look, "灰眸", &["灰眸", "灰瞳", "灰色的眼", "灰色眼"], "grey eyes"),
    w(Look, "异瞳", &["异瞳", "异色瞳"], "heterochromia"),
    w(Look, "白衣", &["白衣", "白袍", "白衫", "白裙", "一袭白"], "white clothes"),
    w(Look, "黑衣", &["黑衣", "黑袍", "黑衫", "黑裙"], "black clothes"),
    w(Look, "青衫", &["青衫", "青衣", "青袍"], "dark blue clothes"),
    w(Look, "红衣", &["红衣", "红裙", "红袍", "嫁衣"], "red clothes"),
    w(Look, "紫衣", &["紫衣", "紫裙", "紫袍"], "purple clothes"),
    w(Look, "眼镜", &["眼镜"], "glasses"),
    w(Look, "斗笠", &["斗笠"], "straw hat"),
    w(Look, "面具", &["面具", "面甲"], "mask"),
    w(Look, "斗篷", &["斗篷", "披风"], "cloak"),
    w(Look, "风衣", &["风衣"], "trench coat"),
    w(Look, "西装", &["西装", "西服"], "suit, necktie"),
    w(Look, "校服", &["校服"], "school uniform"),
    w(Look, "和服", &["和服", "浴衣"], "kimono"),
    w(Look, "旗袍", &["旗袍"], "china dress"),
    w(Look, "铠甲", &["铠甲", "盔甲", "甲胄", "战甲"], "armor"),
    w(Look, "草鞋", &["草鞋"], "straw sandals"),
    // What the lead holds.
    w(Item, "剑", &["剑", "长剑", "佩剑", "宝剑", "古剑", "木剑", "仙剑"], "holding sword"),
    w(Item, "刀", &["刀", "长刀", "唐刀", "短刀", "弯刀", "战刀", "大刀"], "holding sword, saber"),
    w(Item, "长枪", &["长枪", "银枪", "红缨枪", "大枪", "铁枪"], "holding polearm, spear"),
    w(Item, "手枪", &["手枪", "枪械", "步枪", "左轮"], "holding gun, handgun"),
    w(Item, "弓", &["弓", "长弓", "弓箭"], "holding bow (weapon)"),
    w(Item, "折扇", &["折扇", "扇子", "纸扇", "羽扇"], "holding folding fan"),
    w(Item, "伞", &["伞", "油纸伞", "雨伞"], "holding umbrella"),
    w(Item, "葫芦", &["葫芦", "酒葫芦"], "gourd"),
    w(Item, "书", &["书卷", "书籍", "古籍", "书本"], "holding book"),
    w(Item, "笛子", &["笛子", "玉笛", "竹笛", "长笛"], "holding flute"),
    w(Item, "法杖", &["法杖", "魔杖", "权杖", "禅杖"], "holding staff"),
    w(Item, "提灯", &["灯笼", "提灯"], "holding lantern"),
    // Places.
    w(Place, "小镇", &["小镇", "镇子", "镇上", "镇里"], "small town, old buildings"),
    w(Place, "村庄", &["村子", "村庄", "村里", "村口", "山村", "村落"], "village, rural"),
    w(Place, "小巷", &["小巷", "巷子", "巷口", "胡同", "弄堂"], "alley"),
    w(Place, "街道", &["街道", "大街", "街头", "街边", "街上"], "street"),
    w(Place, "竹林", &["竹林", "翠竹"], "bamboo forest"),
    w(Place, "森林", &["森林", "树林", "密林", "林间"], "forest"),
    w(Place, "群山", &["群山", "山峰", "山巅", "山顶", "峰顶", "山脉"], "mountain, mountainous horizon"),
    w(Place, "雪山", &["雪山"], "snowy mountain"),
    w(Place, "江河", &["江面", "江水", "江边", "河边", "河畔", "大江", "河水", "溪水", "小溪"], "river"),
    w(Place, "湖泊", &["湖面", "湖边", "湖畔", "湖水", "湖心"], "lake"),
    w(Place, "大海", &["大海", "海边", "海面", "海浪", "海滩", "沙滩", "海水"], "ocean, horizon"),
    w(Place, "海岛", &["海岛", "岛上", "小岛"], "island, ocean"),
    w(Place, "沙漠", &["沙漠", "黄沙", "戈壁", "荒漠"], "desert"),
    w(Place, "草原", &["草原"], "grassland, field"),
    w(Place, "瀑布", &["瀑布"], "waterfall"),
    w(Place, "桥", &["石桥", "廊桥", "桥上", "桥头", "桥边"], "bridge"),
    w(Place, "宫殿", &["宫殿", "皇宫", "大殿", "宫中", "宫门", "宫墙"], "palace"),
    w(Place, "府邸", &["王府", "府邸", "侯府", "府上", "大宅", "宅子"], "mansion, courtyard"),
    w(Place, "庭院", &["庭院", "院子", "院中", "后院", "院落"], "courtyard"),
    w(Place, "酒楼", &["客栈", "酒楼", "酒馆", "茶楼", "茶馆", "酒肆"], "tavern, indoors"),
    w(Place, "寺庙", &["寺庙", "寺院", "古寺", "庙宇", "佛堂"], "temple"),
    w(Place, "道观", &["道观"], "taoist temple"),
    w(Place, "宗门", &["宗门", "山门", "仙门"], "chinese architecture, mountain, sect"),
    w(Place, "城墙", &["城墙", "城门", "城头", "城楼"], "city wall, gate"),
    w(Place, "战场", &["战场", "沙场", "军营"], "battlefield"),
    w(Place, "学校", &["学校", "校园", "教室", "课堂", "操场"], "school, classroom"),
    w(Place, "学院", &["学院"], "academy, grand building"),
    w(Place, "都市", &["城市", "都市", "高楼", "大厦", "市区", "市中心"], "cityscape, skyscraper"),
    w(Place, "公寓", &["公寓", "出租屋", "宿舍"], "apartment, room, indoors"),
    w(Place, "医院", &["医院", "病房", "病床"], "hospital"),
    w(Place, "办公室", &["办公室", "写字楼"], "office"),
    w(Place, "咖啡馆", &["咖啡馆", "咖啡厅", "咖啡店"], "cafe"),
    w(Place, "便利店", &["便利店"], "convenience store"),
    w(Place, "教堂", &["教堂"], "church, stained glass"),
    w(Place, "墓地", &["墓地", "坟墓", "墓园", "坟地", "墓碑"], "graveyard, tombstone"),
    w(Place, "废墟", &["废墟", "残垣"], "ruins"),
    w(Place, "地下", &["地下室", "地宫", "地下城", "地牢", "密室", "迷宫"], "dungeon"),
    w(Place, "城堡", &["城堡", "古堡"], "castle"),
    w(Place, "码头", &["码头", "港口", "甲板", "渡口"], "pier, boat"),
    w(Place, "列车", &["列车", "火车", "地铁"], "train interior"),
    w(Place, "太空", &["太空", "星舰", "宇宙飞船", "飞船"], "outer space, spaceship"),
    w(Place, "游乐园", &["游乐园", "游乐场", "摩天轮"], "amusement park, ferris wheel"),
    w(Place, "书房", &["图书馆", "书房", "藏书阁"], "bookshelf, books, indoors"),
    w(Place, "舞台", &["舞台", "演唱会", "剧场"], "stage, stage lights"),
    w(Place, "东京", &["东京", "涩谷", "新宿", "秋叶原"], "tokyo (city), japan"),
    // Time and weather.
    w(Sky, "夜晚", &["夜色", "深夜", "夜晚", "夜里", "半夜", "夜幕", "入夜"], "night"),
    w(Sky, "月光", &["月光", "明月", "月色", "圆月", "满月", "皓月"], "moon, moonlight"),
    w(Sky, "星空", &["星空", "繁星", "星光", "星辰"], "starry sky"),
    w(Sky, "雪", &["大雪", "雪花", "积雪", "风雪", "白雪", "下雪", "雪地", "飘雪", "落雪", "雪夜", "冬日", "冬天", "寒冬"], "snow, snowing"),
    w(Sky, "雨", &["大雨", "细雨", "下雨", "雨水", "雨夜", "暴雨", "雨中", "雨幕", "小雨"], "rain"),
    w(Sky, "雾", &["大雾", "雾气", "浓雾", "薄雾", "迷雾", "雾中"], "fog"),
    w(Sky, "黄昏", &["黄昏", "夕阳", "傍晚", "落日", "晚霞", "余晖"], "sunset, orange sky"),
    w(Sky, "清晨", &["清晨", "朝阳", "晨光", "日出", "黎明", "晨曦"], "morning, sunrise"),
    w(Sky, "雷电", &["雷电", "闪电", "雷霆", "惊雷", "雷鸣"], "lightning, dark clouds"),
    // Things in the scene.
    w(Motif, "灯笼", &["灯笼"], "paper lantern"),
    w(Motif, "烛火", &["蜡烛", "烛火", "烛光", "烛台"], "candle"),
    w(Motif, "樱花", &["樱花"], "cherry blossoms"),
    w(Motif, "桃花", &["桃花", "桃林"], "peach blossoms"),
    w(Motif, "梅花", &["梅花", "腊梅", "红梅", "梅林"], "plum blossoms"),
    w(Motif, "杏花", &["杏花"], "apricot blossoms"),
    w(Motif, "荷花", &["荷花", "莲花", "荷叶", "莲叶"], "lotus"),
    w(Motif, "落叶", &["落叶", "枫叶", "红叶"], "autumn leaves, falling leaves"),
    w(Motif, "柳树", &["柳树", "杨柳", "垂柳", "柳枝"], "willow"),
    w(Motif, "猫", &["猫咪", "黑猫", "白猫", "小猫", "猫儿", "橘猫"], "cat"),
    w(Motif, "狐狸", &["狐狸", "狐妖", "狐仙", "九尾"], "fox"),
    w(Motif, "蛇", &["大蛇", "巨蛇", "毒蛇", "白蛇", "黑蛇", "蟒蛇"], "snake"),
    w(Motif, "龙", &[ "巨龙", "真龙", "神龙", "蛟龙", "黑龙", "龙族", "龙王", "青龙", "金龙", "龙类", ], "dragon"),
    w(Motif, "仙鹤", &["仙鹤", "白鹤"], "crane (animal)"),
    w(Motif, "乌鸦", &["乌鸦", "渡鸦"], "crow"),
    w(Motif, "蝴蝶", &["蝴蝶"], "butterfly"),
    w(Motif, "锦鲤", &["锦鲤"], "koi"),
    w(Motif, "骏马", &["骑马", "战马", "马车", "马背", "骏马", "策马"], "horse"),
    w(Motif, "鬼魂", &["鬼魂", "厉鬼", "女鬼", "幽灵", "怨灵", "恶鬼", "鬼影"], "ghost"),
    w(Motif, "骷髅", &["骷髅", "白骨", "骸骨"], "skull"),
    w(Motif, "棺材", &["棺材", "棺椁", "棺木"], "coffin"),
    w(Motif, "符箓", &["符箓", "符纸", "黄符", "符咒"], "ofuda, talisman"),
    w(Motif, "机甲", &["机甲"], "mecha"),
    w(Motif, "飞剑", &["飞剑", "御剑"], "flying sword"),
    w(Motif, "蒸汽", &["蒸汽"], "steampunk"),
    w(Motif, "钟楼", &["钟楼", "钟塔"], "clock tower"),
];

/// Title words too short to be triggers in running text (马 is in 马上), but
/// that in a title mean what they say.
const TITLE: &[(&str, &str)] = &[
    ("剑", "剑"),
    ("刀", "刀"),
    ("龙", "龙"),
    ("冬", "雪"),
    ("雪", "雪"),
    ("夜", "夜晚"),
    ("月", "月光"),
    ("星", "星空"),
    ("樱", "樱花"),
    ("狐", "狐狸"),
    ("猫", "猫"),
    ("鬼", "鬼魂"),
    ("海", "大海"),
    ("岛", "海岛"),
    ("雨", "雨"),
];

/// The word a label names. Labels are unique across kinds.
pub fn word(label: &str) -> Option<&'static Word> {
    VOCABULARY.iter().find(|w| w.label == label)
}

/// How many of a kind one cover takes: one place, one thing in hand, or they
/// fight.
pub fn shown(kind: Kind) -> usize {
    match kind {
        Look | Motif => 2,
        _ => 1,
    }
}

/// What the title names, in vocabulary order within each kind, at most
/// [`shown`] of a kind.
pub fn from_title(title: &str) -> Vec<&'static Word> {
    let mut cues: Vec<&'static Word> = Vec::new();
    for kind in [Role, Look, Item, Place, Sky, Motif] {
        for word in VOCABULARY.iter().filter(|w| w.kind == kind) {
            let named = word.triggers.iter().any(|t| title.contains(t))
                || TITLE
                    .iter()
                    .any(|(t, l)| *l == word.label && title.contains(t));
            if named && cues.iter().filter(|c| c.kind == kind).count() < shown(kind) {
                cues.push(word);
            }
        }
    }
    cues
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(title: &str) -> Vec<&'static str> {
        from_title(title).iter().map(|w| w.label).collect()
    }

    #[test]
    fn every_label_is_unique_and_every_word_has_tags() {
        for (i, a) in VOCABULARY.iter().enumerate() {
            assert!(!a.tags.is_empty(), "{}", a.label);
            assert!(!a.triggers.is_empty(), "{}", a.label);
            // The app sends labels back to name what was picked.
            for b in &VOCABULARY[i + 1..] {
                assert!(a.label != b.label, "{}", a.label);
            }
        }
        for (_, label) in TITLE {
            assert!(word(label).is_some(), "{label}");
        }
    }

    #[test]
    fn a_title_names_what_it_says() {
        assert_eq!(labels("剑来"), ["剑"]);
        assert_eq!(labels("龙族"), ["龙"]);
        assert_eq!(labels("冬日重现"), ["雪"]);
        assert_eq!(labels("东京少女"), ["东京"]);
        assert_eq!(labels("雪中悍刀行"), ["刀", "雪"]);
        assert!(labels("诡秘之主").is_empty());
    }
}
