//! Local image generation: a small anime Stable Diffusion that draws book
//! covers. stable-diffusion.cpp's `sd-cli` is run as a one-shot child per
//! picture, the same arrangement as read-aloud in [`crate::api::tts`]: a data
//! dir the binary and weights live in, shallow file discovery, Windows spawns
//! that never flash a console, and nothing ever leaves the device.
//!
//! The model is Counterfeit V3 with Hyper-SD's 4-step LoRA merged in, its UNet
//! convolutions quantized to Q5 as well (which takes a patched sd.cpp), the VAE
//! left out for TAESD: 0.70 GB, and a 512×768 picture in about 3 s on a laptop
//! RTX 4060, 10 s on an Iris Xe.
//!
//! The prompt is assembled from fixed vocabulary, not written by a model. The
//! reader picks who is on the cover, what world it shows (the book's genre
//! tag picks it to start with) and any tags they like: the words of
//! [`novel_core::cover`] that 章间立绘 reads off the text, and [`EXTRA`] ones
//! only a cover offers. Every choice is
//! Chinese and maps to English tags measured to draw what it says. A 0.6B chat model asked to write tags would be free
//! generation, which [`crate::api::ai`] does not do.

use crate::frb_generated::StreamSink;
use novel_core::cover::{self, Kind, Word};
use novel_core::interlude::{self, Group, Who};
use novel_core::sights;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

static IMAGE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// One kind of drawing's engine run, so the cover dialog and 章间立绘 can each
/// stop their own without stopping the other.
#[flutter_rust_bridge::frb(ignore)]
struct Slot {
    cancel: AtomicBool,
    child: Mutex<Option<Child>>,
}

#[flutter_rust_bridge::frb(ignore)]
impl Slot {
    const fn new() -> Self {
        Slot {
            cancel: AtomicBool::new(false),
            child: Mutex::new(None),
        }
    }

    fn stop(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        if let Some(child) = self.child.lock().unwrap().as_mut() {
            let _ = child.kill();
        }
    }

    fn stopped(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }
}

static COVER: Slot = Slot::new();
static PLATES: Slot = Slot::new();

#[cfg(windows)]
const ENGINE_EXE: &str = "sd-cli.exe";
#[cfg(not(windows))]
const ENGINE_EXE: &str = "sd-cli";

/// The tiny decoder the model is paired with. Its own file, so it is found by
/// name; the model is whichever .gguf sits beside it.
const DECODER: &str = "taesd.safetensors";

/// Called once at startup with `<app-support>/image`. The engine, the model and
/// its decoder live there; the user can also drop files in by hand.
pub fn init_image(dir: String) -> Result<(), String> {
    let p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).map_err(|e| format!("建生图目录失败: {e}"))?;
    let _ = IMAGE_DIR.set(p);
    Ok(())
}

fn image_dir() -> Result<&'static Path, String> {
    IMAGE_DIR
        .get()
        .map(|p| p.as_path())
        .ok_or_else(|| "生图目录未初始化".into())
}

fn find_named(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut subdirs = Vec::new();
    for e in entries.flatten() {
        let p = e.path();
        if p.is_file() && p.file_name().is_some_and(|n| n == name) {
            return Some(p);
        }
        if p.is_dir() {
            subdirs.push(p);
        }
    }
    if depth == 0 {
        return None;
    }
    subdirs.sort();
    subdirs
        .into_iter()
        .find_map(|d| find_named(&d, name, depth - 1))
}

fn find_engine(dir: &Path) -> Option<PathBuf> {
    find_named(dir, ENGINE_EXE, 2)
}

fn find_decoder(dir: &Path) -> Option<PathBuf> {
    find_named(dir, DECODER, 2)
}

/// First .gguf in the image directory, by name for determinism.
fn find_model(dir: &Path) -> Option<PathBuf> {
    let mut models: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.is_file()
                && p.extension()
                    .is_some_and(|x| x.eq_ignore_ascii_case("gguf"))
        })
        .collect();
    models.sort();
    models.into_iter().next()
}

fn file_bytes(p: Option<&PathBuf>) -> i64 {
    p.and_then(|p| std::fs::metadata(p).ok())
        .map(|m| m.len() as i64)
        .unwrap_or(0)
}

/// The model and its decoder, whichever are there. The model only draws with
/// its decoder, so to the reader they are one item: one size, one delete.
fn model_files(dir: &Path) -> Vec<PathBuf> {
    [find_model(dir), find_decoder(dir)]
        .into_iter()
        .flatten()
        .collect()
}

/// The engine and the model, each its own row in AI 设置, the way the chat
/// engine and its models are.
#[derive(Debug, Clone)]
pub struct ImageStatus {
    pub dir: String,
    /// Engine, model and decoder are all there: [`draw_cover`] can run.
    pub ready: bool,
    /// sd-cli is there.
    pub engine: bool,
    pub engine_bytes: i64,
    /// The model's file name without extension, or absent.
    pub model: Option<String>,
    /// The model's decoder is there too.
    pub decoder: bool,
    /// Model and decoder together.
    pub model_bytes: i64,
}

pub fn image_status() -> Result<ImageStatus, String> {
    let dir = image_dir()?;
    let engine = find_engine(dir);
    let model = find_model(dir);
    let decoder = find_decoder(dir).is_some();
    Ok(ImageStatus {
        dir: dir.display().to_string(),
        ready: engine.is_some() && model.is_some() && decoder,
        engine: engine.is_some(),
        engine_bytes: file_bytes(engine.as_ref()),
        model: model
            .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned())),
        decoder,
        model_bytes: model_files(dir).iter().map(|p| file_bytes(Some(p))).sum(),
    })
}

/// The folder the app downloads the engine into, with its licences
/// (`imageEngineFolder` in image_download.dart).
const ENGINE_FOLDER: &str = "sd-cli";

/// Delete the engine. Covers already made are the reader's and stay.
pub fn delete_image_engine() -> Result<(), String> {
    let dir = image_dir()?;
    let exe = find_engine(dir).ok_or("生图引擎未安装")?;
    cancel_cover();
    cancel_plates();
    let folder = dir.join(ENGINE_FOLDER);
    if exe.parent() == Some(folder.as_path()) {
        std::fs::remove_dir_all(&folder)
    } else {
        std::fs::remove_file(&exe)
    }
    .map_err(|e| format!("删除失败: {e}"))
}

/// Delete the model and its decoder. Covers already made stay.
pub fn delete_image_model() -> Result<(), String> {
    let dir = image_dir()?;
    let files = model_files(dir);
    if files.is_empty() {
        return Err("生图模型未安装".into());
    }
    cancel_cover();
    cancel_plates();
    for p in files {
        std::fs::remove_file(&p).map_err(|e| format!("删除失败: {e}"))?;
    }
    Ok(())
}

/// Who is on a 章间立绘 plate.
const SUBJECTS: &[(&str, &str)] = &[
    ("少女", "1girl, solo"),
    ("少年", "1boy, solo"),
    ("无人物", "no humans, scenery"),
];

/// What world the cover shows: the thirteen genres [`novel_core::genre`] tags
/// books with, so a tagged book starts on its own, and a plain illustration for
/// the rest. Each is (label, style, place, light, what a person there wears or
/// holds). A place or a sky the book offers takes the place of the genre's own;
/// the style stays, so a 小巷 in a 都市 book is still modern. What a person
/// wears or holds is dropped for 无人物, because a sword or a uniform in the
/// prompt draws someone to carry it. Every pairing was drawn, on two seeds,
/// before it went in: a dragon, a spaceship or floating islands crowded the
/// person off the cover, "sportswear" drew bloomers, and "bodysuit" drew a
/// girl when asked for a boy.
type Scene = (&'static str, &'static str, &'static str, &'static str, &'static str);

const SCENES: &[Scene] = &[
    ("玄幻", "eastern fantasy, glowing runes, magic aura", "mountains", "epic sky", "flowing robes"),
    ("奇幻", "western fantasy, magic circle", "castle, medieval town", "", "cloak"),
    ("武侠", "wuxia, ancient china", "bamboo forest", "mist", "hanfu, holding sword"),
    ("仙侠", "xianxia, ethereal light", "sea of clouds, mountain peaks", "", "flowing hanfu"),
    ("都市", "modern", "city, street, city lights", "night", "casual clothes"),
    ("现实", "everyday life", "town street", "afternoon sunlight", "casual clothes"),
    ("历史", "ancient china, traditional architecture", "palace, red lanterns", "", "hanfu"),
    ("军事", "", "battlefield, smoke", "dramatic sky", "military uniform"),
    ("游戏", "fantasy", "dungeon, glowing crystals", "", "fantasy armor, adventurer"),
    ("体育", "", "stadium, running track", "sunlight", "tracksuit, jacket, long pants"),
    ("科幻", "science fiction, neon lights", "futuristic city", "starry sky", "futuristic jacket"),
    ("悬疑灵异", "mystery, dark atmosphere", "foggy alley", "night, moonlight", "coat"),
    ("轻小说", "", "classroom, cherry blossoms", "window light", "school uniform"),
    // Not genres a book is tagged with: worlds to pick by hand.
    ("古风", "chinese style, traditional architecture", "pavilion, lotus pond", "", "hanfu"),
    ("宫廷", "ancient china, imperial palace", "palace, red walls", "", "hanfu, hair ornament"),
    ("和风", "japanese style", "shrine, torii", "", "kimono"),
    ("校园", "school life", "school, hallway", "afternoon sunlight", "school uniform"),
    ("民国", "vintage, 1920s", "old town street, gas lamps", "evening", "vintage clothes"),
    ("末世", "post-apocalypse", "ruins, abandoned city", "dusty sky", "tattered clothes, jacket"),
    ("赛博朋克", "cyberpunk, neon lights", "futuristic city, holograms", "night, rain", "techwear"),
    ("蒸汽朋克", "steampunk", "clock tower, gears, airship", "", "victorian clothes, goggles"),
    ("童话", "fairy tale, storybook", "enchanted forest, flowers", "soft light", "fantasy clothes"),
    ("夏日", "summer", "beach, ocean", "blue sky, clouds", "summer clothes"),
    ("插画", "soft lighting", "flowers", "beautiful detailed sky", ""),
];

const QUALITY: &str = "masterpiece, best quality";

/// Text is the one thing SD 1.5 cannot draw, and a cover invites it.
const NEGATIVE: &str = "lowres, bad anatomy, bad hands, extra fingers, fewer fingers, \
    worst quality, low quality, blurry, text, watermark, signature, logo";

/// Who can be on a cover, any number of them: (label, a girl, how old).
/// None picked draws scenery.
const PEOPLE: &[(&str, bool, &str)] = &[
    ("小女孩", true, "child, young girl, small, short"),
    ("少女", true, ""),
    ("成年女性", true, "mature female"),
    ("老婆婆", true, "old woman, grey hair, wrinkled skin"),
    ("小男孩", false, "child, young boy, small, short"),
    ("少年", false, ""),
    ("成年男性", false, "mature male"),
    ("老爷爷", false, "old man, grey hair, wrinkled skin"),
];

/// The people tags for `people`, or None for nobody.
fn people_tags(people: &[String]) -> Result<Option<String>, String> {
    let mut girls = 0;
    let mut boys = 0;
    let mut ages = Vec::new();
    for label in people {
        let &(_, girl, age) = PEOPLE
            .iter()
            .find(|p| p.0 == label)
            .ok_or_else(|| format!("未知的人物选项: {label}"))?;
        if girl {
            girls += 1;
        } else {
            boys += 1;
        }
        if !age.is_empty() && !ages.contains(&age) {
            ages.push(age);
        }
    }
    let count = |n: i32, one: &str, many: &str| match n {
        0 => None,
        1 => Some(format!("1{one}")),
        n => Some(format!("{n}{many}, multiple {many}")),
    };
    let mut parts: Vec<String> = [count(girls, "girl", "girls"), count(boys, "boy", "boys")]
        .into_iter()
        .flatten()
        .collect();
    if parts.is_empty() {
        return Ok(None);
    }
    if girls + boys == 1 {
        parts.push("solo".into());
    }
    parts.extend(ages.iter().map(|a| a.to_string()));
    Ok(Some(parts.join(", ")))
}

/// The choices, as the cover dialog offers them.
#[derive(Debug, Clone)]
pub struct CoverChoices {
    pub people: Vec<String>,
    pub scenes: Vec<String>,
    pub groups: Vec<CoverTagGroup>,
}

/// One row of tags in the cover dialog: pick up to `most` of `labels`.
#[derive(Debug, Clone)]
pub struct CoverTagGroup {
    pub name: String,
    pub labels: Vec<String>,
    pub most: u32,
    /// About the person, so of no use on a cover with nobody on it.
    pub personal: bool,
}

/// The tag groups, in the dialog's order: (name, the kind its tags are, how
/// many can be picked, which of the text vocabulary's words it holds: those of
/// the kind and, for looks, of the part). The model blurs past a few of a
/// kind, so each stops short of that.
const TAG_GROUPS: &[(&str, Kind, u32, Option<Option<Group>>)] = &[
    ("身份", Kind::Role, 2, Some(None)),
    ("发色", Kind::Look, 2, Some(Some(Group::HairColour))),
    ("发型", Kind::Look, 3, Some(Some(Group::Hair))),
    ("眼睛", Kind::Look, 2, Some(Some(Group::Eyes))),
    ("服饰", Kind::Look, 4, Some(Some(Group::Outfit))),
    ("表情", Kind::Look, 2, None),
    ("动作", Kind::Look, 2, None),
    ("手持", Kind::Item, 2, Some(None)),
    ("地点", Kind::Place, 2, Some(None)),
    ("时间天气", Kind::Sky, 3, Some(None)),
    ("景物", Kind::Motif, 4, Some(None)),
    ("构图", Kind::Motif, 2, None),
    ("画风", Kind::Motif, 2, None),
];

const fn x(group: &'static str, kind: Kind, label: &'static str, tags: &'static str) -> (&'static str, Word) {
    (group, Word { kind, label, triggers: &[], tags })
}

/// Tags only a cover offers: what 章间立绘 cannot read off the text (a smile,
/// a pose, the framing) and more places, clothes and things than the text
/// vocabulary has.
const EXTRA: &[(&str, Word)] = &[
    x("发色", Kind::Look, "渐变发", "gradient hair, multicolored hair"),
    x("发色", Kind::Look, "挑染", "streaked hair"),
    x("发型", Kind::Look, "侧马尾", "side ponytail"),
    x("发型", Kind::Look, "丸子头", "hair bun"),
    x("发型", Kind::Look, "麻花辫", "braid"),
    x("发型", Kind::Look, "卷发", "wavy hair"),
    x("发型", Kind::Look, "姬发式", "hime cut"),
    x("发型", Kind::Look, "呆毛", "ahoge"),
    x("发型", Kind::Look, "刘海", "blunt bangs"),
    x("发型", Kind::Look, "长直发", "very long hair, straight hair"),
    x("眼睛", Kind::Look, "黑瞳", "black eyes"),
    x("眼睛", Kind::Look, "棕瞳", "brown eyes"),
    x("眼睛", Kind::Look, "闭眼", "closed eyes"),
    x("服饰", Kind::Look, "水手服", "serafuku"),
    x("服饰", Kind::Look, "连衣裙", "dress"),
    x("服饰", Kind::Look, "白衬衫", "white shirt"),
    x("服饰", Kind::Look, "毛衣", "sweater"),
    x("服饰", Kind::Look, "卫衣", "hoodie"),
    x("服饰", Kind::Look, "夹克", "jacket"),
    x("服饰", Kind::Look, "大衣", "long coat"),
    x("服饰", Kind::Look, "围巾", "scarf"),
    x("服饰", Kind::Look, "汉服", "hanfu"),
    x("服饰", Kind::Look, "道袍", "taoist robe"),
    x("服饰", Kind::Look, "哥特裙", "gothic lolita"),
    x("服饰", Kind::Look, "礼服", "evening gown"),
    x("服饰", Kind::Look, "燕尾服", "tailcoat"),
    x("服饰", Kind::Look, "军装", "military uniform"),
    x("服饰", Kind::Look, "巫师帽", "witch hat"),
    x("服饰", Kind::Look, "贝雷帽", "beret"),
    x("服饰", Kind::Look, "发饰", "hair ornament"),
    x("服饰", Kind::Look, "发带", "hair ribbon"),
    x("服饰", Kind::Look, "耳机", "headphones"),
    x("服饰", Kind::Look, "猫耳", "cat ears"),
    x("服饰", Kind::Look, "狐耳", "fox ears, fox tail"),
    x("服饰", Kind::Look, "兽角", "horns"),
    x("服饰", Kind::Look, "翅膀", "wings"),
    x("服饰", Kind::Look, "光环", "halo"),
    x("服饰", Kind::Look, "眼罩", "eyepatch"),
    x("表情", Kind::Look, "微笑", "smile"),
    x("表情", Kind::Look, "大笑", "laughing, open mouth"),
    x("表情", Kind::Look, "冷淡", "expressionless"),
    x("表情", Kind::Look, "害羞", "blush, embarrassed"),
    x("表情", Kind::Look, "生气", "angry"),
    x("表情", Kind::Look, "哭泣", "crying, tears"),
    x("表情", Kind::Look, "坚定", "serious, determined"),
    x("表情", Kind::Look, "温柔", "gentle smile"),
    x("动作", Kind::Look, "站立", "standing"),
    x("动作", Kind::Look, "坐着", "sitting"),
    x("动作", Kind::Look, "回眸", "looking back"),
    x("动作", Kind::Look, "看向镜头", "looking at viewer"),
    x("动作", Kind::Look, "仰望", "looking up"),
    x("动作", Kind::Look, "奔跑", "running"),
    x("动作", Kind::Look, "伸手", "outstretched hand"),
    x("动作", Kind::Look, "抱膝", "hugging own legs"),
    x("动作", Kind::Look, "背影", "from behind"),
    x("动作", Kind::Look, "战斗姿态", "fighting stance"),
    x("动作", Kind::Look, "读书", "reading"),
    x("手持", Kind::Item, "花束", "holding bouquet"),
    x("手持", Kind::Item, "酒杯", "holding cup"),
    x("手持", Kind::Item, "信", "holding letter"),
    x("手持", Kind::Item, "镰刀", "holding scythe"),
    x("手持", Kind::Item, "匕首", "holding dagger"),
    x("手持", Kind::Item, "琴", "guqin"),
    x("手持", Kind::Item, "吉他", "holding guitar"),
    x("手持", Kind::Item, "手机", "holding phone"),
    x("手持", Kind::Item, "猫咪", "holding cat"),
    x("地点", Kind::Place, "神社", "shrine, torii"),
    x("地点", Kind::Place, "天台", "school rooftop, chain-link fence, sky"),
    x("地点", Kind::Place, "教室", "classroom, window"),
    x("地点", Kind::Place, "走廊", "hallway"),
    x("地点", Kind::Place, "图书馆", "library, bookshelf"),
    x("地点", Kind::Place, "卧室", "bedroom, bed, window, curtains, indoors"),
    x("地点", Kind::Place, "花海", "flower field"),
    x("地点", Kind::Place, "向日葵田", "sunflower field"),
    x("地点", Kind::Place, "樱花道", "cherry blossom trees, path"),
    x("地点", Kind::Place, "雪原", "snowfield"),
    x("地点", Kind::Place, "冰川", "glacier, ice"),
    x("地点", Kind::Place, "火山", "volcano, lava"),
    x("地点", Kind::Place, "古镇", "chinese old town, canal"),
    x("地点", Kind::Place, "亭台楼阁", "pavilion, chinese architecture"),
    x("地点", Kind::Place, "长城", "great wall of china"),
    x("地点", Kind::Place, "夜市", "night market, stalls"),
    x("地点", Kind::Place, "祭典", "summer festival, yatai"),
    x("地点", Kind::Place, "车站", "train station, platform"),
    x("地点", Kind::Place, "灯塔", "lighthouse"),
    x("地点", Kind::Place, "花园", "garden"),
    x("地点", Kind::Place, "温室", "greenhouse"),
    x("地点", Kind::Place, "温泉", "onsen, steam"),
    x("地点", Kind::Place, "水下", "underwater"),
    x("地点", Kind::Place, "云海", "sea of clouds"),
    x("地点", Kind::Place, "浮空岛", "floating island"),
    x("地点", Kind::Place, "天宫", "heavenly palace, clouds"),
    x("地点", Kind::Place, "魔法阵", "glowing magic circle on the ground, runes"),
    x("地点", Kind::Place, "王座", "throne, throne room, red carpet"),
    x("地点", Kind::Place, "神殿", "temple ruins, pillars"),
    x("地点", Kind::Place, "霓虹街", "neon street, signs"),
    x("地点", Kind::Place, "空间站", "space station interior, window, earth in background"),
    x("地点", Kind::Place, "星球", "alien planet surface, giant planet in the sky"),
    x("时间天气", Kind::Sky, "晴天", "blue sky, clouds"),
    x("时间天气", Kind::Sky, "午后阳光", "afternoon, sunlight"),
    x("时间天气", Kind::Sky, "阴天", "overcast, grey sky"),
    x("时间天气", Kind::Sky, "极光", "aurora"),
    x("时间天气", Kind::Sky, "流星", "shooting star"),
    x("时间天气", Kind::Sky, "银河", "milky way, starry sky, night"),
    x("时间天气", Kind::Sky, "彩虹", "rainbow"),
    x("时间天气", Kind::Sky, "大风", "strong wind, flying leaves"),
    x("时间天气", Kind::Sky, "春天", "spring, cherry blossoms, green grass"),
    x("时间天气", Kind::Sky, "夏天", "summer, blue sky, cumulonimbus cloud, green trees"),
    x("时间天气", Kind::Sky, "秋天", "autumn, autumn leaves, orange trees"),
    x("时间天气", Kind::Sky, "冬天", "winter, snow, bare trees"),
    x("景物", Kind::Motif, "羽毛", "feathers"),
    x("景物", Kind::Motif, "气泡", "many bubbles, floating bubbles"),
    x("景物", Kind::Motif, "花瓣", "petals"),
    x("景物", Kind::Motif, "萤火虫", "fireflies"),
    x("景物", Kind::Motif, "孔明灯", "sky lantern"),
    x("景物", Kind::Motif, "烟花", "fireworks"),
    x("景物", Kind::Motif, "风铃", "wind chime"),
    x("景物", Kind::Motif, "鸟群", "flock of birds, flying birds"),
    x("景物", Kind::Motif, "鲸", "giant whale flying in the sky"),
    x("景物", Kind::Motif, "火焰", "fire"),
    x("景物", Kind::Motif, "冰晶", "ice crystals"),
    x("景物", Kind::Motif, "光粒", "light particles"),
    x("景物", Kind::Motif, "锁链", "chains, chained, hanging chains"),
    x("景物", Kind::Motif, "钟表", "clock"),
    x("景物", Kind::Motif, "书页", "flying paper"),
    x("景物", Kind::Motif, "月亮", "full moon"),
    x("构图", Kind::Motif, "特写", "close-up, portrait"),
    x("构图", Kind::Motif, "半身", "upper body"),
    x("构图", Kind::Motif, "全身", "full body"),
    x("构图", Kind::Motif, "远景", "wide shot, scenery"),
    x("构图", Kind::Motif, "俯视", "from above"),
    x("构图", Kind::Motif, "仰视", "from below"),
    x("构图", Kind::Motif, "侧脸", "profile"),
    x("画风", Kind::Motif, "逆光", "backlighting"),
    x("画风", Kind::Motif, "柔光", "soft lighting"),
    x("画风", Kind::Motif, "电影感", "cinematic lighting"),
    x("画风", Kind::Motif, "水彩", "watercolor (medium)"),
    x("画风", Kind::Motif, "厚涂", "painterly"),
    x("画风", Kind::Motif, "暖色调", "warm colors"),
    x("画风", Kind::Motif, "冷色调", "cool colors"),
    x("画风", Kind::Motif, "黑白", "monochrome"),
    x("画风", Kind::Motif, "复古", "retro artstyle"),
    x("画风", Kind::Motif, "景深", "depth of field"),
];

/// Clothes that dress the person whole, so the genre's own go.
const OUTFITS: &[&str] = &[
    "水手服", "连衣裙", "汉服", "道袍", "哥特裙", "礼服", "燕尾服", "军装", "白衬衫", "毛衣",
    "卫衣", "夹克", "大衣",
];

/// The tag a cover label names: the text vocabulary's, then [`EXTRA`].
fn cover_word(label: &str) -> Option<&'static Word> {
    cover::word(label).or_else(|| EXTRA.iter().find(|e| e.1.label == label).map(|e| &e.1))
}

pub fn cover_choices() -> CoverChoices {
    CoverChoices {
        people: PEOPLE.iter().map(|p| p.0.to_string()).collect(),
        scenes: SCENES.iter().map(|s| s.0.to_string()).collect(),
        groups: TAG_GROUPS
            .iter()
            .map(|&(name, kind, most, text)| CoverTagGroup {
                name: name.into(),
                labels: cover::VOCABULARY
                    .iter()
                    .filter(|w| text == Some(interlude::group(w)) && w.kind == kind)
                    .chain(EXTRA.iter().filter(|e| e.0 == name).map(|e| &e.1))
                    .map(|w| w.label.to_string())
                    .collect(),
                most,
                personal: personal(kind),
            })
            .collect(),
    }
}

/// The scene a book starts on: its first genre tag, or the plain illustration.
pub fn default_cover_scene(genre_tags: Vec<String>) -> String {
    genre_tags
        .iter()
        .find(|g| SCENES.iter().any(|s| s.0 == g.as_str()))
        .cloned()
        .unwrap_or_else(|| SCENES[SCENES.len() - 1].0.to_string())
}

/// How many of each kind of cue go into one picture: one place and one
/// thing in hand, or they fight; a few looks; a sky and its weather.
fn cue_limit(kind: Kind) -> usize {
    match kind {
        Kind::Role | Kind::Item | Kind::Place => 1,
        Kind::Look => 3,
        Kind::Sky | Kind::Motif => 2,
    }
}

/// Whether a cue is about the person drawn, so it goes when no one is.
fn personal(kind: Kind) -> bool {
    matches!(kind, Kind::Role | Kind::Look | Kind::Item)
}

/// A cover keeps every tag picked: the dialog already holds each group to a
/// few.
fn cover_limit(_: Kind) -> usize {
    usize::MAX
}

/// `title`, when not empty, goes in as it is, the way a tag does.
fn cover_prompt(
    people: &[String],
    scenes: &[String],
    title: &str,
    cues: &[String],
) -> Result<String, String> {
    let who = people_tags(people)?;
    let cues = cues
        .iter()
        .map(|l| cover_word(l).ok_or_else(|| format!("未知的标签: {l}")))
        .collect::<Result<Vec<_>, _>>()?;
    let scenes: Vec<&str> = scenes.iter().map(|s| s.as_str()).collect();
    let title = title.trim();
    let title = (!title.is_empty()).then_some(title);
    prompt(who.as_deref(), &scenes, title, cues, true, cover_limit)
}

/// A 章间立绘 plate's prompt: the cover's, with what the text said in place of
/// what the title says.
fn plate_prompt(scene: &str, plate: &interlude::Plate) -> Result<String, String> {
    let who = match plate.who {
        Who::Girl(_) => Some(SUBJECTS[0].1),
        Who::Boy(_) => Some(SUBJECTS[1].1),
        Who::Nobody => return Ok(still_prompt(scene, &plate.cues)),
    };
    let mut cues = plate.cues.clone();
    // Left to itself the model picks a hair colour per picture, often the
    // eyes' (blue eyes, blue hair), and the same lead changes from plate to
    // plate. In a Chinese setting the text not saying means black.
    let person = plate.who != Who::Nobody;
    let coloured = cues
        .iter()
        .any(|w| interlude::group(w) == Some(Group::HairColour));
    if person && !coloured && BLACK_HAIRED.contains(&scene) {
        cues.insert(0, cover::word("黑发").ok_or("缺少黑发")?);
    }
    // A plate holds only what the text gave the lead to hold.
    prompt(who, &[scene], None, cues, false, cue_limit)
}

/// A plate with no one on it: the thing or the sight first, as a still life or
/// scenery, then the place and the light of its passage. The genre gives only
/// its style: its own place would put a pencil case in a bamboo forest.
/// A thing keeps only the light: a place or the weather drowns it
/// (a phone in a snowy shop drew snowballs). A room or a street in an old
/// China is told its period, or it comes out a modern flat.
fn still_prompt(scene: &str, cues: &[&'static Word]) -> String {
    let object = cues.first().is_some_and(|w| sights::is_object(w));
    let framing = if object { "still life" } else { "scenery" };
    let style = SCENES.iter().find(|s| s.0 == scene).map_or("", |s| s.1);
    let mut parts = vec![QUALITY, "no humans", framing];
    parts.extend(
        cues.iter()
            .enumerate()
            .filter(|(i, w)| *i == 0 || !object || LIGHT.contains(&w.label))
            .map(|(_, w)| w.tags),
    );
    parts.push(style);
    if ANCIENT.contains(&scene) && cues.first().is_some_and(|w| BUILT.contains(&w.label)) {
        parts.push(PERIOD);
    }
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| !p.is_empty() && seen.insert(*p));
    parts.join(", ")
}

/// The skies that are only light, kept around a thing drawn on its own.
const LIGHT: &[&str] = &["夜晚", "月光", "黄昏", "清晨", "黑暗", "阳光"];

/// Scenes set in old China.
const ANCIENT: &[&str] = &["玄幻", "武侠", "仙侠", "历史", "古风", "宫廷"];

/// Rooms, streets and what stands in them, which the model builds modern
/// whatever the genre's style says: 剑来's alleys, bedrooms, desks and doors
/// came out as flats and office corridors. Hills, rivers and things in the
/// hand need no period, and drawn with one they fill up with lanterns.
const BUILT: &[&str] = &[
    "书房", "仓库", "卧室", "厨房", "客厅", "浴室", "餐厅", "走廊", "楼梯", "小巷",
    "街道", "府邸", "庭院", "酒楼", "围墙", "房门", "窗户", "书桌", "床", "椅子",
];

/// What tells the model a room is in old China. "ancient china" alone, or
/// with "chinese architecture", still drew the modern flat.
const PERIOD: &str = "chinese style, east asian architecture, paper lantern, wooden";

/// Scenes set in China, where a lead whose hair the text never colours has
/// black hair.
const BLACK_HAIRED: &[&str] = &["玄幻", "武侠", "仙侠", "都市", "现实", "历史", "军事", "体育"];

/// Looks that are a whole outfit, so the genre's clothes go. A colour (白衣)
/// is the colour of the genre's clothes, and stays with them.
const GARMENTS: &[&str] = &["风衣", "西装", "校服", "和服", "旗袍", "铠甲"];

/// `who` (people tags, None for nobody) in `scenes` (any number, together),
/// with `cues` laid over the scenes' own.
/// `title`: words put in as they are. `props`: whether the person holds the
/// scene's own prop (a 武侠 sword) when the cues give them nothing to hold.
/// `limit`: how many of a kind are kept.
fn prompt(
    who: Option<&str>,
    scenes: &[&str],
    title: Option<&str>,
    cues: Vec<&'static Word>,
    props: bool,
    limit: fn(Kind) -> usize,
) -> Result<String, String> {
    let rows = scenes
        .iter()
        .map(|&scene| {
            SCENES
                .iter()
                .find(|s| s.0 == scene)
                .ok_or_else(|| format!("未知的场景选项: {scene}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let column = |f: fn(&Scene) -> &'static str| -> Vec<&'static str> {
        rows.iter().map(|r| f(*r)).collect()
    };
    let nobody = who.is_none();

    // Past a kind's limit, and the person's cues for 无人物, are left out.
    let mut picked: Vec<&Word> = Vec::new();
    for w in cues {
        let same = picked.iter().filter(|p| p.kind == w.kind).count();
        if same < limit(w.kind) && !(nobody && personal(w.kind)) {
            picked.push(w);
        }
    }
    let tags = |kind: Kind| -> Vec<&str> {
        picked
            .iter()
            .filter(|w| w.kind == kind)
            .map(|w| w.tags)
            .collect()
    };
    let has = |kind: Kind| picked.iter().any(|w| w.kind == kind);
    let dressed = has(Kind::Role)
        || picked
            .iter()
            .any(|w| GARMENTS.contains(&w.label) || OUTFITS.contains(&w.label));

    let mut parts: Vec<&str> = vec![QUALITY, who.unwrap_or(SUBJECTS[2].1)];
    parts.extend(title);
    if !nobody {
        parts.extend(tags(Kind::Role));
        parts.extend(tags(Kind::Look));
        parts.extend(tags(Kind::Item));
        // The genre's clothes give way to what the book says the lead is or
        // wears, and its sword to what the lead holds.
        for attire in column(|r| r.4) {
            parts.extend(attire.split(", ").filter(|a| {
                if a.starts_with("holding") {
                    props && !has(Kind::Item)
                } else {
                    !dressed
                }
            }));
        }
    }
    parts.extend(column(|r| r.1));
    parts.extend(if has(Kind::Place) { tags(Kind::Place) } else { column(|r| r.2) });
    parts.extend(if has(Kind::Sky) { tags(Kind::Sky) } else { column(|r| r.3) });
    parts.extend(tags(Kind::Motif));
    // A 斗篷 in a 奇幻 scene is the genre's cloak again.
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| !p.is_empty() && seen.insert(*p));
    Ok(parts.join(", "))
}

#[derive(Debug, Clone)]
pub struct CoverProgress {
    /// 0 preparing (loading the model, reading the prompt), 1 drawing,
    /// 2 decoding, 3 done.
    pub stage: u8,
    /// Steps drawn so far / steps in all, while drawing.
    pub step: u32,
    pub steps: u32,
    /// The finished picture, in the temp dir, on the last event.
    pub path: Option<String>,
}

/// Stop a picture being drawn. The dialog calls it on close too.
pub fn cancel_cover() {
    COVER.stop();
}

fn next_tmp() -> PathBuf {
    static N: AtomicU64 = AtomicU64::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("novel_cover_{}_{n}.png", std::process::id()))
}

/// 2:3, the shape of a cover, and the size the model was measured at.
const WIDTH: u32 = 512;
const HEIGHT: u32 = 768;
const STEPS: u32 = 4;

/// Draw one cover and stream where it has got to. `people`, `scenes` and
/// `cues` are labels from [`cover_choices`]; no people draws scenery. `title`
/// (empty for none) goes into the prompt. `seed` makes a picture repeatable;
/// the dialog rolls a new one for 换一张.
pub fn draw_cover(
    people: Vec<String>,
    scenes: Vec<String>,
    title: String,
    cues: Vec<String>,
    seed: u32,
    sink: StreamSink<CoverProgress>,
) -> Result<(), String> {
    draw(&people, &scenes, &title, &cues, seed, |p| {
        let _ = sink.add(p);
    })
}

/// [`draw_cover`] without the bridge, so a test can run it.
fn draw(
    people: &[String],
    scenes: &[String],
    title: &str,
    cues: &[String],
    seed: u32,
    mut report: impl FnMut(CoverProgress),
) -> Result<(), String> {
    COVER.cancel.store(false, Ordering::SeqCst);
    let prompt = cover_prompt(people, scenes, title, cues)?;
    let out = render(&COVER, &prompt, seed, &mut report)?;
    report(CoverProgress {
        stage: 3,
        step: STEPS,
        steps: STEPS,
        path: Some(out.display().to_string()),
    });
    Ok(())
}

/// Run the engine once, into a temp file. `slot` says whose run it is; a stop
/// asked of it before or during the run ends it.
fn render(
    slot: &Slot,
    prompt: &str,
    seed: u32,
    report: &mut impl FnMut(CoverProgress),
) -> Result<PathBuf, String> {
    let dir = image_dir()?;
    let exe = find_engine(dir).ok_or("生图引擎未安装（缺 sd-cli）")?;
    let model = find_model(dir).ok_or("生图模型未安装")?;
    let decoder = find_decoder(dir).ok_or("生图模型不完整（缺 taesd）")?;
    let out = next_tmp();

    let mut cmd = Command::new(&exe);
    cmd.arg("-m")
        .arg(&model)
        .arg("--taesd")
        .arg(&decoder)
        .args(["--clip-skip", "2", "--fa"])
        .args(["-W", &WIDTH.to_string(), "-H", &HEIGHT.to_string()])
        // Hyper-SD's 4 steps: TCD sampling, no classifier-free guidance.
        .args(["--steps", &STEPS.to_string(), "--cfg-scale", "1"])
        .args(["--sampling-method", "tcd"])
        // Decoding the whole picture at once needs 720 MB of scratch — more than
        // the model itself. Full-width strips, a bit over a third of the height
        // each, cap it at 270 MB, under what drawing already needs, so peak
        // memory falls by 430 MB. Strips overlap by half so the seams blend out;
        // square tiles re-decode more pixels for the same cap.
        .args(["--vae-tiling", "--vae-relative-tile-size", "1x0.375"])
        .args(["--vae-tile-overlap", "0.5"])
        .args(["-s", &seed.to_string()])
        .arg("-p")
        .arg(prompt)
        .arg("-n")
        .arg(NEGATIVE)
        .arg("--disable-image-metadata")
        .arg("-o")
        .arg(&out);
    // Without a backend sd.cpp fits everything on the best GPU it finds.
    if crate::api::ai::cpu_only() {
        cmd.args(["--backend", "cpu"]);
    }
    cmd.current_dir(exe.parent().unwrap_or(dir))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }

    if slot.stopped() {
        return Err("已取消".into());
    }
    let mut child = cmd.spawn().map_err(|e| format!("启动生图引擎失败: {e}"))?;
    crate::job::adopt(&child);
    let mut stdout = child.stdout.take().ok_or("生图引擎没有输出")?;
    let mut stderr = child.stderr.take().ok_or("生图引擎没有输出")?;
    *slot.child.lock().unwrap() = Some(child);
    // A stop that landed between the check above and the child being kept
    // found nothing to kill.
    if slot.stopped() {
        slot.stop();
    }
    // A pipe nobody drains fills up and stalls the child.
    let errors = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr.read_to_string(&mut s);
        s
    });

    report(CoverProgress {
        stage: 0,
        step: 0,
        steps: STEPS,
        path: None,
    });
    let mut log = Log::default();
    let mut buf = [0u8; 4096];
    let mut line = Vec::new();
    loop {
        let n = match stdout.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        for &b in &buf[..n] {
            // Progress bars redraw themselves with \r.
            if b == b'\n' || b == b'\r' {
                if let Some(p) = log.feed(&String::from_utf8_lossy(&line)) {
                    report(p);
                }
                line.clear();
            } else {
                line.push(b);
            }
        }
    }

    let status = slot
        .child
        .lock()
        .unwrap()
        .take()
        .map(|mut c| c.wait())
        .transpose()
        .map_err(|e| format!("生图引擎异常: {e}"))?;
    let err_text = errors.join().unwrap_or_default();
    if slot.stopped() {
        let _ = std::fs::remove_file(&out);
        return Err("已取消".into());
    }
    if !status.is_some_and(|s| s.success()) || !out.exists() {
        let _ = std::fs::remove_file(&out);
        let why = log.error.or_else(|| {
            err_text
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_string())
        });
        return Err(match why {
            Some(why) => format!("生图失败：{why}"),
            None => "生图失败".into(),
        });
    }
    Ok(out)
}

/// Where a book's 章间立绘 are kept: `<data>/plates/<book id>/<chapter>.png`,
/// the chapter being the one a plate follows. Drawn again if deleted.
fn plates_dir(book_id: i64) -> Result<PathBuf, String> {
    Ok(crate::api::book::data_dir()?
        .join("plates")
        .join(book_id.to_string()))
}

/// The plate drawn to follow `chapter`, if there is one.
pub fn plate_path(book_id: i64, chapter: u32) -> Option<String> {
    let p = plates_dir(book_id).ok()?.join(format!("{chapter}.png"));
    p.is_file().then(|| p.display().to_string())
}

/// The chapters a plate has been drawn after, in order.
pub fn plate_chapters(book_id: i64) -> Vec<u32> {
    let Some(entries) = plates_dir(book_id)
        .ok()
        .and_then(|d| std::fs::read_dir(d).ok())
    else {
        return Vec::new();
    };
    let mut chapters: Vec<u32> = entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "png"))
        .filter_map(|e| e.path().file_stem()?.to_str()?.parse::<u32>().ok())
        .collect();
    chapters.sort_unstable();
    chapters
}

/// Plates drawn so far at `every` chapters apart.
pub fn plates_drawn(book_id: i64, every: u32) -> u32 {
    let every = every.max(1);
    plate_chapters(book_id)
        .into_iter()
        .filter(|c| (c + 1) % every == 0)
        .count() as u32
}

/// Delete a book's plates, from the 章间立绘 page. A run in progress for it
/// is the caller's to stop first.
pub fn clear_plates(book_id: i64) {
    drop_plates(book_id);
}

/// With the book, or with its AI data.
pub(crate) fn drop_plates(book_id: i64) {
    if let Ok(dir) = plates_dir(book_id) {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[derive(Debug, Clone)]
pub struct PlateProgress {
    /// Plates there are, drawn now or before.
    pub done: u32,
    /// Plates the book has at this frequency.
    pub total: u32,
}

/// Pause 章间立绘. What is drawn stays.
pub fn cancel_plates() {
    PLATES.stop();
}

/// Draw a book's 章间立绘, every `every` chapters, those not yet drawn, the
/// ones ahead of the reader first. A pause ends it early without an error;
/// the next run picks up what is left.
pub fn draw_plates(
    path: String,
    book_id: i64,
    every: u32,
    sink: StreamSink<PlateProgress>,
) -> Result<(), String> {
    plates(&path, book_id, every, |p| {
        let _ = sink.add(p);
    })
}

/// [`draw_plates`] without the bridge, so a test can run it.
fn plates(
    path: &str,
    book_id: i64,
    every: u32,
    mut report: impl FnMut(PlateProgress),
) -> Result<(), String> {
    PLATES.cancel.store(false, Ordering::SeqCst);
    let (genre_tags, reading) = crate::api::book::plate_context(book_id)?;
    let plan = crate::api::book::plate_plan(path, book_id, every.max(1) as usize)?;
    let scene = default_cover_scene(genre_tags);
    let dir = plates_dir(book_id)?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("建立插画目录失败: {e}"))?;
    let file = |p: &interlude::Plate| dir.join(format!("{}.png", p.chapter));

    let total = plan.len() as u32;
    let mut todo: Vec<&interlude::Plate> = plan.iter().filter(|p| !file(p).is_file()).collect();
    todo.sort_by_key(|p| (p.chapter < reading, p.chapter));
    let mut done = total - todo.len() as u32;
    report(PlateProgress { done, total });
    for p in todo {
        if PLATES.stopped() {
            return Ok(());
        }
        let prompt = plate_prompt(&scene, p)?;
        let out = match render(&PLATES, &prompt, p.seed, &mut |_| {}) {
            Ok(out) => out,
            Err(_) if PLATES.stopped() => return Ok(()),
            Err(e) => return Err(e),
        };
        // The temp dir can be on another drive, where a rename fails.
        let to = file(p);
        if std::fs::rename(&out, &to).is_err() {
            let copied = std::fs::copy(&out, &to);
            let _ = std::fs::remove_file(&out);
            copied.map_err(|e| format!("保存插画失败: {e}"))?;
        }
        done += 1;
        report(PlateProgress { done, total });
    }
    Ok(())
}

/// Reads sd-cli's console output for where it has got to. Its log lines say
/// which phase it is in; the progress bars under them count steps.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct Log {
    stage: u8,
    error: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl Log {
    fn feed(&mut self, line: &str) -> Option<CoverProgress> {
        let line = line.trim();
        if line.starts_with("[E]") {
            let msg = line.trim_start_matches("[E]");
            let msg = msg.split(" --- ").next().unwrap_or(msg).trim();
            self.error.get_or_insert_with(|| msg.to_string());
            return None;
        }
        if line.contains("generating image:") {
            self.stage = 1;
            return Some(self.at(0));
        }
        if line.contains("decoding 1 latents") || line.contains("decoding latents") {
            self.stage = 2;
            return Some(self.at(STEPS));
        }
        // "|=====>     | 2/4 - 6.31it/s" (or "7.81s/it" on a slow CPU): a
        // sampling step. Weight loading draws "#" bars in "MB/s", and decoding
        // counts its strips; neither is a step.
        if self.stage == 1
            && line.starts_with('|')
            && (line.contains("it/s") || line.contains("s/it"))
        {
            let tail = line.rsplit('|').next()?.trim();
            let done: u32 = tail.split('/').next()?.trim().parse().ok()?;
            return Some(self.at(done.min(STEPS)));
        }
        None
    }

    fn at(&self, step: u32) -> CoverProgress {
        CoverProgress {
            stage: self.stage,
            step,
            steps: STEPS,
            path: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_genre_tag_has_a_scene() {
        // The genres novel-core tags books with, in its order.
        let genres = [
            "玄幻", "奇幻", "武侠", "仙侠", "都市", "现实", "历史", "军事", "游戏", "体育", "科幻",
            "悬疑灵异", "轻小说",
        ];
        for g in genres {
            assert_eq!(default_cover_scene(vec![g.to_string()]), g);
        }
        assert_eq!(default_cover_scene(vec![]), "插画");
        assert_eq!(
            default_cover_scene(vec!["未知".into(), "武侠".into()]),
            "武侠"
        );
    }

    fn strings(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|x| x.to_string()).collect()
    }

    /// One person (无人物 for none) and what the title names, as the dialog
    /// used to send it.
    fn prompt(subject: &str, scene: &str, title: &str) -> Result<String, String> {
        let people = if subject == "无人物" { vec![] } else { strings(&[subject]) };
        let cues: Vec<String> = cover::from_title(title).iter().map(|w| w.label.to_string()).collect();
        cover_prompt(&people, &strings(&[scene]), "", &cues)
    }

    fn picked(people: &[&str], scene: &str, labels: &[&str]) -> Result<String, String> {
        cover_prompt(&strings(people), &strings(&[scene]), "", &strings(labels))
    }

    #[test]
    fn every_tag_is_offered_once() {
        let offered: Vec<String> = cover_choices().groups.into_iter().flat_map(|g| g.labels).collect();
        assert_eq!(offered.len(), cover::VOCABULARY.len() + EXTRA.len());
        for (i, a) in offered.iter().enumerate() {
            assert!(!offered[i + 1..].contains(a), "{a}");
            assert!(cover_word(a).is_some(), "{a}");
        }
        for (group, w) in EXTRA {
            assert!(TAG_GROUPS.iter().any(|g| g.0 == *group && g.1 == w.kind), "{}", w.label);
        }
        for o in OUTFITS {
            assert!(EXTRA.iter().any(|e| e.1.label == *o), "{o}");
        }
    }

    #[test]
    fn picked_tags_make_the_prompt() {
        assert_eq!(picked(&["少女"], "都市", &["不存在"]).unwrap_err(), "未知的标签: 不存在");
        assert_eq!(
            picked(&["少女"], "都市", &["银发", "双马尾", "红瞳", "和服", "伞", "雨", "樱花"]).unwrap(),
            "masterpiece, best quality, 1girl, solo, silver hair, twintails, red eyes, kimono, \
             holding umbrella, modern, city, street, city lights, rain, cherry blossoms"
        );
        // Several of a group, a cover's own tags, and a whole outfit that
        // replaces the genre's clothes.
        assert_eq!(
            picked(&["少年"], "武侠", &["微笑", "水手服", "神社", "天台", "特写", "水彩"]).unwrap(),
            "masterpiece, best quality, 1boy, solo, smile, serafuku, holding sword, wuxia, \
             ancient china, shrine, torii, school rooftop, chain-link fence, sky, mist, \
             close-up, portrait, \
             watercolor (medium)"
        );
        // Nothing picked is the genre alone.
        assert_eq!(picked(&["少年"], "武侠", &[]).unwrap(), prompt("少年", "武侠", "").unwrap());
    }

    #[test]
    fn scenes_mix_and_the_title_goes_in() {
        assert_eq!(
            cover_prompt(&strings(&["少女"]), &strings(&["武侠", "夏日"]), " 剑来 ", &[]).unwrap(),
            "masterpiece, best quality, 1girl, solo, 剑来, hanfu, holding sword, summer clothes, wuxia, ancient china, summer, bamboo forest, beach, ocean, mist, blue sky, clouds"
        );
        // No scene at all is the person and the tags alone.
        assert_eq!(
            cover_prompt(&strings(&["少年"]), &[], "", &strings(&["雪"])).unwrap(),
            "masterpiece, best quality, 1boy, solo, snow, snowing"
        );
    }

    #[test]
    fn people_are_counted_and_aged() {
        let who = |p: &[&str]| people_tags(&strings(p)).unwrap();
        assert_eq!(who(&[]), None);
        assert_eq!(who(&["少女"]).unwrap(), "1girl, solo");
        assert_eq!(who(&["老爷爷"]).unwrap(), "1boy, solo, old man, grey hair, wrinkled skin");
        assert_eq!(
            who(&["少女", "成年女性", "少年"]).unwrap(),
            "2girls, multiple girls, 1boy, mature female"
        );
        assert!(people_tags(&strings(&["猫"])).is_err());
        // Nobody holds nothing.
        assert_eq!(
            picked(&[], "武侠", &["剑", "微笑", "竹林"]).unwrap(),
            "masterpiece, best quality, no humans, scenery, wuxia, ancient china, bamboo forest, mist"
        );
    }

    #[test]
    fn prompt_is_built_from_the_two_choices() {
        assert_eq!(
            prompt("少女", "武侠", "").unwrap(),
            "masterpiece, best quality, 1girl, solo, hanfu, holding sword, \
             wuxia, ancient china, bamboo forest, mist"
        );
        // Nobody to hold the sword, so no sword.
        assert_eq!(
            prompt("无人物", "武侠", "").unwrap(),
            "masterpiece, best quality, no humans, scenery, \
             wuxia, ancient china, bamboo forest, mist"
        );
        assert_eq!(
            prompt("少年", "插画", "").unwrap(),
            "masterpiece, best quality, 1boy, solo, \
             soft lighting, flowers, beautiful detailed sky"
        );
        assert!(prompt("少女", "不存在", "").is_err());
        assert!(prompt("猫", "仙侠", "").is_err());
        assert_eq!(
            prompt("少女", "赛博朋克", "").unwrap(),
            "masterpiece, best quality, 1girl, solo, techwear, cyberpunk, neon lights, \
             futuristic city, holograms, night, rain"
        );
    }

    #[test]
    fn what_the_title_names_replaces_the_genres_own() {
        // A sky takes over from the genre's; its style stays. What the lead
        // holds takes the genre's sword, and a role its clothes.
        assert_eq!(
            prompt("少年", "武侠", "雪中悍刀行").unwrap(),
            "masterpiece, best quality, 1boy, solo, holding sword, saber, hanfu, \
             wuxia, ancient china, bamboo forest, snow, snowing"
        );
        assert_eq!(
            prompt("少年", "武侠", "大周世子").unwrap(),
            "masterpiece, best quality, 1boy, solo, hanfu, noble, hair ornament, \
             holding sword, wuxia, ancient china, bamboo forest, mist"
        );
        // The person's cues go with the person.
        assert_eq!(
            prompt("无人物", "都市", "东京剑客").unwrap(),
            "masterpiece, best quality, no humans, scenery, modern, \
             tokyo (city), japan, night"
        );
    }

    /// Every word the vocabulary has makes a prompt.
    #[test]
    fn every_cue_makes_a_prompt() {
        for w in cover::VOCABULARY.iter().chain(EXTRA.iter().map(|e| &e.1)) {
            picked(&["少女"], "插画", &[w.label]).unwrap();
        }
    }

    #[cfg(windows)]
    fn installed() -> bool {
        let dir = PathBuf::from(std::env::var("APPDATA").unwrap())
            .join("com.novel")
            .join("novel")
            .join("image");
        let _ = init_image(dir.display().to_string());
        image_status().unwrap().ready
    }

    /// Draws a real cover with what is installed in the app's image folder:
    /// `cargo test --lib draws_a_real_cover -- --ignored --nocapture`
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn draws_a_real_cover() {
        assert!(installed(), r"nothing installed in %APPDATA%\com.novel\novel\image");
        let mut seen = Vec::new();
        draw(&strings(&["少女"]), &strings(&["仙侠"]), "", &[], 7, |p| seen.push(p)).unwrap();
        let stages: Vec<(u8, u32)> = seen.iter().map(|p| (p.stage, p.step)).collect();
        println!("{stages:?}");
        assert_eq!(stages.first(), Some(&(0, 0)));
        assert!(stages.contains(&(1, STEPS)), "every step reported");
        assert!(stages.windows(2).all(|w| w[0] <= w[1]), "never goes backwards");
        let last = seen.last().unwrap();
        assert_eq!(last.stage, 3);
        let path = last.path.clone().unwrap();
        assert!(std::fs::metadata(&path).unwrap().len() > 100_000);
        std::fs::remove_file(path).unwrap();
    }

    #[cfg(windows)]
    #[test]
    #[ignore]
    fn a_cancelled_cover_leaves_nothing() {
        assert!(installed());
        let before = leftovers();
        let r = draw(&strings(&["少年"]), &strings(&["武侠"]), "", &[], 7, |p| {
            if p.stage == 1 && p.step == 1 {
                cancel_cover();
            }
        });
        assert_eq!(r, Err("已取消".to_string()));
        assert_eq!(leftovers(), before);
    }

    #[cfg(windows)]
    fn leftovers() -> usize {
        std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("novel_cover_"))
            .count()
    }

    /// Every prompt the dialog can send, for drawing them all side by side
    /// before a change to the vocabulary goes in:
    /// `cargo test --lib all_cover_prompts -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn all_cover_prompts() {
        println!("negative\t\t{NEGATIVE}");
        for subject in ["少女", "少年", "无人物"] {
            for (scene, ..) in SCENES {
                println!("{subject}\t{scene}\t{}", prompt(subject, scene, "").unwrap());
            }
        }
    }

    /// The prompt each book in a folder gets by default — its genre, a girl and
    /// A plate wears what the text said over the genre's clothes, or in their
    /// colour, holds only what the text said it holds, and in a Chinese
    /// setting has black hair unless the text says otherwise.
    #[test]
    fn a_plate_draws_what_the_text_said() {
        let plate = |who, labels: &[&str], seed| interlude::Plate {
            chapter: 9,
            who,
            cues: labels
                .iter()
                .map(|l| cover::word(l).or_else(|| sights::all().find(|w| w.label == *l)).unwrap())
                .collect(),
            seed,
        };
        assert_eq!(
            plate_prompt("武侠", &plate(Who::Girl(0), &["白衣", "长发", "剑", "竹林"], 1)).unwrap(),
            "masterpiece, best quality, 1girl, solo, black hair, white clothes, long hair, \
             holding sword, hanfu, wuxia, ancient china, bamboo forest, mist"
        );
        assert_eq!(
            plate_prompt("武侠", &plate(Who::Boy(1), &["校服", "学校", "雨"], 1)).unwrap(),
            "masterpiece, best quality, 1boy, solo, black hair, school uniform, wuxia, \
             ancient china, school, classroom, rain"
        );
        assert_eq!(
            plate_prompt("奇幻", &plate(Who::Girl(2), &["金发", "斗篷"], 1)).unwrap(),
            "masterpiece, best quality, 1girl, solo, blonde hair, cloak, western fantasy, \
             magic circle, castle, medieval town"
        );
        assert_eq!(
            plate_prompt("都市", &plate(Who::Nobody, &["大海", "黄昏", "樱花"], 1)).unwrap(),
            "masterpiece, best quality, no humans, scenery, ocean, horizon, sunset, \
             orange sky, cherry blossoms, modern"
        );
        // Something up close keeps the light of its passage, not the place or
        // the weather.
        assert_eq!(
            plate_prompt("都市", &plate(Who::Nobody, &["铅笔盒", "学校", "雪", "黑暗"], 1)).unwrap(),
            "masterpiece, best quality, no humans, still life, pencil case, \
             stationery, dark, darkness, modern"
        );
        assert_eq!(
            plate_prompt("悬疑灵异", &plate(Who::Nobody, &["地道", "黑暗"], 1)).unwrap(),
            "masterpiece, best quality, no humans, scenery, tunnel, underground, dark, \
             darkness, mystery, dark atmosphere"
        );
        // A room in old China is told so; a coin there is not.
        assert_eq!(
            plate_prompt("仙侠", &plate(Who::Nobody, &["卧室", "清晨"], 1)).unwrap(),
            "masterpiece, best quality, no humans, scenery, bedroom, morning, sunrise, \
             xianxia, ethereal light, chinese style, east asian architecture, \
             paper lantern, wooden"
        );
        assert_eq!(
            plate_prompt("仙侠", &plate(Who::Nobody, &["钱币", "夜晚"], 1)).unwrap(),
            "masterpiece, best quality, no humans, still life, coin, night, xianxia, \
             ethereal light"
        );
        for l in BUILT {
            assert!(cover::word(l).or_else(|| sights::all().find(|w| w.label == *l)).is_some(), "{l}");
        }
    }

    /// The whole of 章间立绘 on a real book and the real engine, in a library of
    /// its own: plan, draw, keep, and a second run that finds nothing to do.
    /// `PLATE_BOOK=<txt> cargo test --release --lib plates_end_to_end -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn plates_end_to_end() {
        use crate::api::book;
        assert!(installed(), r"nothing installed in %APPDATA%\com.novel\novel\image");
        let src = std::env::var("PLATE_BOOK").expect("PLATE_BOOK");
        let data = std::env::temp_dir().join(format!("novel_plates_{}", std::process::id()));
        book::init_store(data.display().to_string()).unwrap();
        let path = data.join("book.txt");
        // A short book: the first 60 chapters' worth of text is plenty.
        let text = std::fs::read_to_string(&src).unwrap();
        let cut = text.char_indices().nth(400_000).map_or(text.len(), |(i, _)| i);
        std::fs::write(&path, &text[..cut]).unwrap();
        let path = path.display().to_string();
        let id = book::open_book(path.clone()).unwrap().id;

        let mut seen = Vec::new();
        plates(&path, id, 20, |p| seen.push((p.done, p.total))).unwrap();
        println!("{seen:?}");
        let &(done, total) = seen.last().unwrap();
        assert!(total > 0 && done == total, "{seen:?}");
        let drawn = plates_drawn(id, 20);
        assert_eq!(drawn, total);
        for c in (0..200).filter(|c| (c + 1) % 20 == 0) {
            if let Some(p) = plate_path(id, c) {
                println!("{c}: {p}");
            }
        }

        let mut again = Vec::new();
        plates(&path, id, 20, |p| again.push((p.done, p.total))).unwrap();
        assert_eq!(again, [(total, total)], "nothing left to draw");

        drop_plates(id);
        assert_eq!(plates_drawn(id, 20), 0);
        book::close_book(path);
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Draws every cover-only tag and every scene once, on a girl (scenery for
    /// places and skies), into a folder, to look at before tags go in:
    /// `COVER_OUT=<dir> cargo test --release --lib draws_cover_tags -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn draws_cover_tags() {
        assert!(installed(), r"nothing installed in %APPDATA%\com.novel\novel\image");
        let out = PathBuf::from(std::env::var("COVER_OUT").expect("COVER_OUT"));
        std::fs::create_dir_all(&out).unwrap();
        let mut jobs: Vec<(String, String)> = Vec::new();
        for (group, w) in EXTRA {
            let people: &[&str] = match w.kind {
                Kind::Place | Kind::Sky => &[],
                _ => &["少女"],
            };
            jobs.push((format!("{group}_{}", w.label), picked(people, "插画", &[w.label]).unwrap()));
        }
        for (scene, ..) in &SCENES[13..] {
            jobs.push((format!("题材_{scene}"), picked(&["少女"], scene, &[]).unwrap()));
        }
        for p in PEOPLE {
            jobs.push((format!("人物_{}", p.0), picked(&[p.0], "插画", &[]).unwrap()));
        }
        jobs.push(("人物_两人".into(), picked(&["少女", "少年"], "都市", &[]).unwrap()));
        for title in ["剑来", "雪中悍刀行", "诡秘之主", "我的青春恋爱物语果然有问题"] {
            for (tag, t) in [("无", ""), ("有", title)] {
                let p = cover_prompt(&strings(&["少女"]), &strings(&["插画"]), t, &[]).unwrap();
                jobs.push((format!("书名{tag}_{title}"), p));
            }
        }
        // COVER_ONLY=<label,label>: just those, to redraw a few.
        if let Ok(only) = std::env::var("COVER_ONLY") {
            let only: Vec<&str> = only.split(',').collect();
            jobs.retain(|(name, _)| only.iter().any(|o| name.ends_with(&format!("_{o}"))));
        }
        for (name, prompt) in jobs {
            println!("{name}\t{prompt}");
            let png = render(&COVER, &prompt, 7, &mut |_| {}).unwrap();
            std::fs::copy(&png, out.join(format!("{name}.png"))).unwrap();
            std::fs::remove_file(png).unwrap();
        }
    }

    /// Draws a book's first plates into a folder, to look at:
    /// `PLATE_BOOK=<txt> PLATE_OUT=<dir> [PLATE_EVERY=50] [PLATE_MAX=12]
    ///  cargo test --release --lib draws_book_plates -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn draws_book_plates() {
        use novel_core::{book, cast, decode, fingerprint, genre};
        assert!(installed(), r"nothing installed in %APPDATA%\com.novel\novel\image");
        let path = std::env::var("PLATE_BOOK").expect("PLATE_BOOK");
        let out = PathBuf::from(std::env::var("PLATE_OUT").expect("PLATE_OUT"));
        let num = |k: &str, d: usize| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
        std::fs::create_dir_all(&out).unwrap();
        let d = decode::decode(&std::fs::read(&path).unwrap());
        let b = book::build(&d.text, &fingerprint::fingerprint(d.encoding, &d.text));
        let c = cast::scan(&d.text, &b.chapters, b.chapters.len());
        let leads: Vec<Vec<String>> = c
            .people
            .iter()
            .take(8)
            .map(|p| std::iter::once(p.name.clone()).chain(p.aliases.iter().cloned()).collect())
            .collect();
        let scene = default_cover_scene(genre::tags(&d.text).iter().map(|t| t.to_string()).collect());
        let plates = interlude::plan(&d.text, &b.chapters, &leads, num("PLATE_EVERY", 50));
        for p in plates.iter().take(num("PLATE_MAX", 12)) {
            let who = match p.who {
                Who::Girl(i) | Who::Boy(i) => leads[i][0].as_str(),
                Who::Nobody => p.cues[0].label,
            };
            let prompt = plate_prompt(&scene, p).unwrap();
            println!("{}\t{who}\t{prompt}", p.chapter + 1);
            let png = render(&PLATES, &prompt, p.seed, &mut |_| {}).unwrap();
            std::fs::copy(&png, out.join(format!("{:04}_{who}.png", p.chapter + 1))).unwrap();
            std::fs::remove_file(png).unwrap();
        }
    }

    /// a boy, and what its title names — for drawing them:
    /// `COVER_CORPUS=<dir> cargo test --lib book_cover_prompts -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn book_cover_prompts() {
        use novel_core::{decode, genre};
        let dir = std::env::var("COVER_CORPUS").expect("COVER_CORPUS");
        let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "txt"))
            .collect();
        paths.sort();
        for (i, path) in paths.iter().enumerate() {
            let d = decode::decode(&std::fs::read(path).unwrap());
            let title = path.file_stem().unwrap().to_string_lossy().to_string();
            let cues: Vec<&str> = cover::from_title(&title).iter().map(|w| w.label).collect();
            let tags: Vec<String> = genre::tags(&d.text).iter().map(|t| t.to_string()).collect();
            let scene = default_cover_scene(tags);
            for subject in ["少女", "少年"] {
                let p = prompt(subject, &scene, &title).unwrap();
                println!("b{i:02}_{subject}\t{p}\t{title}|{scene}|{}", cues.join(" "));
            }
        }
    }

    #[test]
    fn log_follows_sd_cli_through_its_phases() {
        let mut log = Log::default();
        // Weight loading before drawing: not a step.
        assert!(log
            .feed("  |######        | 273/686 - 747.32MB/s\u{1b}[K")
            .is_none());
        let p = log
            .feed("[I] generating image: 1/1 - seed 7 --- image.cpp:866")
            .unwrap();
        assert_eq!((p.stage, p.step), (1, 0));
        assert!(log.feed("  |######   | 686/686 - 1.38GB/s\u{1b}[K").is_none());
        let p = log
            .feed("  |=========================>      | 2/4 - 6.31it/s\u{1b}[K")
            .unwrap();
        assert_eq!((p.stage, p.step), (1, 2));
        let p = log
            .feed("  |=====================================>  | 3/4 - 7.81s/it\u{1b}[K")
            .unwrap();
        assert_eq!((p.stage, p.step), (1, 3));
        let p = log
            .feed("[I] decoding 1 latents --- image.cpp:554")
            .unwrap();
        assert_eq!((p.stage, p.step), (2, 4));
        // Decoding strips are counted by the same bar, but are not steps.
        assert!(log.feed("  |=====>    | 1/4 - 2.96it/s\u{1b}[K").is_none());
        assert!(log
            .feed("[E] failed to allocate buffer --- ggml_runner.cpp:10")
            .is_none());
        assert_eq!(log.error.as_deref(), Some("failed to allocate buffer"));
    }
}
