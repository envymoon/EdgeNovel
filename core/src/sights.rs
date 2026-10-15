//! What a 章间立绘 can be of besides a person: the things and the sights a
//! passage dwells on — a pencil case, a dark tunnel, a lighthouse. Like the
//! cover's vocabulary ([`crate::cover`]) each is Chinese words tied to the
//! English tags the image model reads; nothing is translated freehand.
//!
//! Objects are [`Kind::Motif`] and drawn on their own as a still life; sights are
//! [`Kind::Place`] and drawn as scenery; moods are [`Kind::Sky`], the light a
//! passage sets around either. Every trigger is two characters or more: one
//! character sits inside too many other words.

use crate::cover::{Kind, Word};

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

/// Things held, used, eaten, kept: drawn on their own, close up.
pub const OBJECTS: &[Word] = &[
    // School and desk.
    w(Motif, "铅笔盒", &["铅笔盒", "文具盒", "笔袋"], "pencil case, stationery"),
    w(Motif, "钢笔", &["钢笔", "圆珠笔", "铅笔"], "pen"),
    w(Motif, "笔记本", &["笔记本", "日记本", "本子", "作业本"], "notebook"),
    w(Motif, "课本", &["课本", "教科书", "试卷", "练习册"], "book, paper"),
    w(Motif, "信", &["信封", "信纸", "情书", "书信"], "envelope, letter"),
    w(Motif, "照片", &["照片", "相片", "合影", "相框", "相册"], "framed photo, portrait photo"),
    w(Motif, "黑板", &["黑板", "粉笔"], "chalkboard"),
    w(Motif, "书桌", &["书桌", "课桌", "桌面", "桌上"], "desk"),
    w(Motif, "书包", &["书包", "背包", "双肩包", "挎包"], "backpack"),
    // Things that tell the time, light a room, make a sound.
    w(Motif, "钥匙", &["钥匙"], "key"),
    w(Motif, "电脑", &["电脑", "笔记本电脑", "键盘", "显示器"], "computer, keyboard"),
    w(Motif, "相机", &["相机", "照相机", "胶卷", "镜头"], "camera"),
    w(Motif, "手表", &["手表", "腕表"], "watch, wristwatch"),
    w(Motif, "怀表", &["怀表"], "pocket watch"),
    w(Motif, "时钟", &["闹钟", "时钟", "挂钟", "座钟"], "clock"),
    w(Motif, "收音机", &["收音机", "录音机", "磁带", "随身听"], "radio, cassette tape"),
    w(Motif, "耳机", &["耳机"], "headphones"),
    w(Motif, "台灯", &["台灯", "灯泡", "吊灯", "油灯"], "lamp"),
    w(Motif, "手电筒", &["手电筒", "手电"], "flashlight"),
    w(Motif, "风铃", &["风铃"], "wind chime"),
    w(Motif, "铃铛", &["铃铛", "铜铃"], "bell"),
    w(Motif, "大钟", &["铜钟", "大钟", "钟声"], "bell, temple bell"),
    // Music and games.
    w(Motif, "吉他", &["吉他"], "guitar"),
    w(Motif, "钢琴", &["钢琴", "琴键"], "piano"),
    w(Motif, "小提琴", &["小提琴"], "violin"),
    w(Motif, "古琴", &["古琴", "古筝", "琴弦", "琵琶"], "guqin"),
    w(Motif, "棋盘", &["棋盘", "象棋", "围棋", "棋子", "棋局"], "go (game), board game"),
    w(Motif, "纸牌", &["扑克", "纸牌", "塔罗"], "playing card"),
    w(Motif, "骰子", &["骰子"], "dice"),
    w(Motif, "游戏机", &["游戏机", "手柄", "掌机"], "handheld game console"),
    w(Motif, "玩偶", &["玩偶", "布偶", "毛绒玩具", "玩具熊", "公仔"], "stuffed toy"),
    w(Motif, "风筝", &["风筝"], "kite"),
    w(Motif, "雪人", &["雪人"], "snowman"),
    // Worn and kept.
    w(Motif, "围巾", &["围巾"], "scarf"),
    w(Motif, "手套", &["手套"], "gloves"),
    w(Motif, "帽子", &["帽子", "毛线帽", "草帽"], "hat"),
    w(Motif, "鞋子", &["鞋子", "皮鞋", "运动鞋", "高跟鞋"], "shoes"),
    w(Motif, "镜子", &["镜子", "铜镜", "镜面", "梳妆台"], "mirror"),
    w(Motif, "梳子", &["梳子", "木梳"], "comb"),
    w(Motif, "口红", &["口红", "化妆品"], "lipstick, cosmetics"),
    w(Motif, "香水", &["香水"], "perfume bottle"),
    w(Motif, "戒指", &["戒指", "婚戒"], "ring"),
    w(Motif, "项链", &["项链", "吊坠"], "necklace, pendant"),
    w(Motif, "发簪", &["发簪", "簪子", "发卡", "发夹", "头绳"], "hairpin, hair ornament"),
    w(Motif, "手镯", &["手镯", "玉镯", "手链"], "bracelet"),
    w(Motif, "玉佩", &["玉佩", "玉牌", "玉简", "玉石"], "jade, pendant"),
    w(Motif, "宝石", &["宝石", "水晶", "钻石", "晶石"], "gem, crystal"),
    w(Motif, "钱币", &["金币", "银币", "硬币", "铜钱", "铜板"], "coin"),
    w(Motif, "礼物", &["礼物", "礼盒", "包装纸"], "gift box, ribbon"),
    w(Motif, "箱子", &["箱子", "木箱", "盒子", "铁盒"], "box"),
    w(Motif, "行李箱", &["行李箱", "行李"], "suitcase"),
    w(Motif, "宝箱", &["宝箱"], "treasure chest"),
    w(Motif, "瓶子", &["瓶子", "玻璃瓶", "药瓶", "罐子"], "bottle"),
    w(Motif, "丹药", &["丹药", "药丸", "灵丹", "丹炉"], "pill, glowing"),
    w(Motif, "药片", &["药片", "胶囊", "针管", "注射器", "针筒"], "pill, syringe"),
    w(Motif, "地图", &["地图"], "map"),
    w(Motif, "罗盘", &["罗盘", "指南针"], "compass"),
    w(Motif, "望远镜", &["望远镜"], "telescope"),
    w(Motif, "锁链", &["锁链", "铁链", "绳子", "绳索"], "chain, rope"),
    w(Motif, "门锁", &["铁锁", "门锁", "锁头", "锁孔"], "padlock"),
    w(Motif, "房门", &["房门", "木门", "铁门", "门把", "大门"], "door"),
    w(Motif, "窗户", &["窗户", "窗台", "窗帘", "窗外", "玻璃窗"], "window, curtains"),
    w(Motif, "床", &["床铺", "被子", "枕头", "被窝"], "bed, pillow"),
    w(Motif, "沙发", &["沙发"], "couch"),
    w(Motif, "椅子", &["椅子", "长椅", "板凳"], "chair"),
    // Old China.
    w(Motif, "香炉", &["香炉", "檀香", "熏香", "香火"], "incense"),
    w(Motif, "雕像", &["佛像", "雕像", "石像", "神像", "塑像"], "statue"),
    w(Motif, "画卷", &["画卷", "画像", "油画", "壁画", "画框"], "painting (object)"),
    w(Motif, "卷轴", &["卷轴", "竹简", "古卷"], "scroll"),
    w(Motif, "毛笔", &["毛笔", "砚台", "墨汁", "宣纸"], "calligraphy brush, ink, paper"),
    w(Motif, "旗帜", &["旗帜", "旗子", "大旗", "战旗", "旗杆"], "flag"),
    w(Motif, "盾牌", &["盾牌"], "shield"),
    w(Motif, "头盔", &["头盔"], "helmet"),
    // Food and drink.
    w(Motif, "蛋糕", &["蛋糕"], "cake"),
    w(Motif, "便当", &["便当", "饭盒"], "bento"),
    w(Motif, "饺子", &["饺子", "汤圆", "包子", "馒头"], "dumpling"),
    w(Motif, "火锅", &["火锅"], "hot pot"),
    w(Motif, "面条", &["面条", "拉面", "泡面", "米线"], "ramen, noodles, bowl"),
    w(Motif, "烧烤", &["烧烤", "烤肉", "烤串"], "grilled meat, skewer"),
    w(Motif, "汤", &["热汤", "汤碗", "鸡汤"], "soup, bowl"),
    w(Motif, "咖啡", &["咖啡"], "coffee, cup"),
    w(Motif, "茶", &["茶杯", "茶壶", "茶水", "茶盏", "热茶"], "tea, teacup, teapot"),
    w(Motif, "酒", &["酒杯", "酒瓶", "啤酒", "红酒", "酒坛"], "alcohol, glass"),
    w(Motif, "奶茶", &["奶茶", "饮料", "可乐", "汽水"], "drink, cup, straw"),
    w(Motif, "糖果", &["糖果", "棒棒糖", "奶糖", "糖葫芦"], "candy"),
    w(Motif, "巧克力", &["巧克力"], "chocolate"),
    w(Motif, "冰淇淋", &["冰淇淋", "雪糕", "冰棍"], "ice cream"),
    w(Motif, "水果", &["苹果", "橘子", "橙子", "葡萄", "草莓", "西瓜", "桃子"], "fruit"),
    w(Motif, "花束", &["花束", "玫瑰", "鲜花", "花瓶"], "bouquet, flowers"),
    w(Motif, "向日葵", &["向日葵"], "sunflower"),
    // Animals.
    w(Motif, "狗", &["小狗", "狗子", "黑狗", "黄狗", "狼狗", "大狗"], "dog"),
    w(Motif, "兔子", &["兔子", "小兔"], "rabbit"),
    w(Motif, "鸟", &["小鸟", "麻雀", "鸽子", "飞鸟", "鸟儿"], "bird"),
    w(Motif, "海鸥", &["海鸥"], "seagull"),
    w(Motif, "金鱼", &["金鱼", "鱼缸"], "goldfish, fishbowl"),
    w(Motif, "狼", &["狼群", "野狼", "白狼", "灰狼", "巨狼"], "wolf"),
    w(Motif, "老虎", &["老虎", "猛虎", "白虎"], "tiger"),
    w(Motif, "鹿", &["小鹿", "梅花鹿", "麋鹿"], "deer"),
    w(Motif, "萤火虫", &["萤火虫", "流萤"], "fireflies"),
    w(Motif, "蛛网", &["蜘蛛", "蛛网"], "spider web"),
    // Fire and ice.
    w(Motif, "篝火", &["篝火", "火堆", "火盆"], "campfire"),
    w(Motif, "火焰", &["火焰", "大火", "烈火", "火海", "火舌"], "fire, flames"),
    w(Motif, "冰", &["冰面", "冰层", "冰柱", "冰块", "冰凌"], "ice"),
    // Getting about.
    w(Motif, "自行车", &["自行车", "单车"], "bicycle"),
    w(Motif, "摩托车", &["摩托车", "摩托", "电动车"], "motorcycle"),
    w(Motif, "汽车", &["汽车", "轿车", "跑车", "出租车", "车窗"], "car"),
    w(Motif, "公交车", &["公交车", "公交", "大巴"], "bus"),
    w(Motif, "船", &["小船", "渔船", "木船", "帆船", "轮船", "船舱", "船头"], "boat"),
    w(Motif, "飞机", &["飞机", "客机"], "airplane"),
];

/// Where a passage lingers: drawn as scenery, with no one in it.
pub const SIGHTS: &[Word] = &[
    w(Place, "地道", &["地道", "隧道", "坑道", "地洞", "暗道", "下水道"], "tunnel, underground"),
    w(Place, "山洞", &["山洞", "洞穴", "洞口", "溶洞", "石洞"], "cave"),
    w(Place, "古井", &["古井", "水井", "井口", "井底"], "well"),
    w(Place, "天台", &["天台", "屋顶", "楼顶", "房顶"], "rooftop"),
    w(Place, "走廊", &["走廊", "长廊", "过道", "楼道"], "hallway"),
    w(Place, "楼梯", &["楼梯", "台阶", "阶梯", "石阶"], "stairs"),
    w(Place, "电梯", &["电梯"], "elevator, indoors"),
    w(Place, "厨房", &["厨房", "灶台", "灶房"], "kitchen"),
    w(Place, "浴室", &["浴室", "浴缸", "卫生间", "洗手间"], "bathroom"),
    w(Place, "卧室", &["卧室", "房间", "卧房", "闺房"], "bedroom"),
    w(Place, "客厅", &["客厅"], "living room"),
    w(Place, "仓库", &["仓库", "储物间", "杂物间", "库房"], "storage room"),
    w(Place, "工厂", &["工厂", "厂房", "车间"], "factory"),
    w(Place, "工地", &["工地"], "construction site"),
    w(Place, "车站", &["车站", "站台", "月台"], "train station"),
    w(Place, "铁轨", &["铁轨", "铁路"], "railroad tracks"),
    w(Place, "机场", &["机场"], "airport"),
    w(Place, "停车场", &["停车场"], "parking lot"),
    w(Place, "商场", &["商场", "超市", "商店", "小卖部"], "shop"),
    w(Place, "餐厅", &["餐厅", "饭店", "食堂", "饭馆", "面馆"], "restaurant"),
    w(Place, "网吧", &["网吧", "游戏厅", "电玩城"], "arcade"),
    w(Place, "夜市", &["夜市", "集市", "庙会", "摊位", "小摊"], "market stall"),
    w(Place, "公园", &["公园", "广场"], "park"),
    w(Place, "体育馆", &["体育馆", "篮球场", "球场"], "gymnasium"),
    w(Place, "泳池", &["游泳池", "泳池"], "pool"),
    w(Place, "小路", &["小路", "小径", "山路", "石板路", "土路"], "path"),
    w(Place, "田野", &["田野", "稻田", "麦田", "田埂", "农田"], "field, rice paddy"),
    w(Place, "花海", &["花海", "花田", "花丛", "花园"], "flower field"),
    w(Place, "山坡", &["山坡", "山丘", "山腰", "山脚"], "hill"),
    w(Place, "悬崖", &["悬崖", "峭壁", "崖边", "深渊"], "cliff"),
    w(Place, "大树", &["大树", "古树", "老树", "槐树", "银杏", "榕树"], "tree, large tree"),
    w(Place, "灯塔", &["灯塔"], "lighthouse"),
    w(Place, "海岸", &["海岸", "岸边", "堤坝", "防波堤", "礁石"], "shore, rock"),
    w(Place, "雪原", &["雪原", "冰原"], "snowfield"),
    w(Place, "温泉", &["温泉"], "onsen"),
    w(Place, "池塘", &["池塘", "水塘", "荷塘"], "pond"),
    w(Place, "神社", &["神社", "鸟居"], "shrine, torii"),
    w(Place, "古塔", &["高塔", "宝塔", "古塔", "塔顶"], "pagoda, tower"),
    w(Place, "屋檐", &["屋檐", "房檐", "瓦片", "青瓦"], "roof, eaves"),
    w(Place, "围墙", &["围墙", "院墙", "高墙", "墙壁"], "wall"),
    w(Place, "废弃楼", &["废弃", "荒废", "烂尾楼"], "abandoned building"),
    w(Place, "霓虹", &["霓虹", "灯火", "路灯"], "city lights, neon lights"),
    w(Place, "烟花", &["烟花", "烟火", "焰火"], "fireworks, night sky"),
];

/// The light a passage sets.
pub const MOODS: &[Word] = &[
    w(Sky, "黑暗", &["漆黑", "黑漆漆", "黑暗", "昏暗", "黑乎乎", "阴暗", "伸手不见五指"], "dark, darkness"),
    w(Sky, "阳光", &["阳光", "日光", "烈日", "骄阳"], "sunlight"),
    w(Sky, "大风", &["狂风", "大风", "寒风", "风声"], "wind"),
    w(Sky, "云", &["云海", "云层", "白云", "乌云"], "clouds"),
    w(Sky, "彩虹", &["彩虹"], "rainbow"),
    w(Sky, "极光", &["极光"], "aurora"),
    w(Sky, "银河", &["银河", "星河"], "milky way"),
    w(Sky, "流星", &["流星"], "shooting star"),
    w(Sky, "烟雾", &["烟雾", "浓烟"], "smoke"),
];

/// Whether `w` is one of [`OBJECTS`], drawn as a still life.
pub fn is_object(w: &Word) -> bool {
    OBJECTS.iter().any(|o| std::ptr::eq(o, w))
}

/// Whether `w` is one of [`SIGHTS`].
pub fn is_sight(w: &Word) -> bool {
    SIGHTS.iter().any(|o| std::ptr::eq(o, w))
}

/// Every word here.
pub fn all() -> impl Iterator<Item = &'static Word> {
    OBJECTS.iter().chain(SIGHTS).chain(MOODS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cover::VOCABULARY;

    #[test]
    fn labels_and_triggers_are_unique_and_long_enough() {
        let words: Vec<&Word> = VOCABULARY.iter().chain(all()).collect();
        let mut triggers = std::collections::HashMap::new();
        for (i, a) in words.iter().enumerate() {
            for b in &words[i + 1..] {
                assert!(a.label != b.label, "{}", a.label);
            }
        }
        for a in all() {
            assert!(!a.tags.is_empty() && !a.triggers.is_empty(), "{}", a.label);
            for t in a.triggers {
                assert!(t.chars().count() >= 2, "{t}");
                assert!(triggers.insert(*t, a.label).is_none(), "{t}");
            }
        }
        // Nor one the cover's vocabulary already has.
        for a in VOCABULARY {
            for t in a.triggers {
                assert!(!triggers.contains_key(t), "{t}");
            }
        }
    }
}
