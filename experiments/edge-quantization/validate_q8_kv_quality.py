from __future__ import annotations

import argparse
import importlib.util
import json
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


RELATION_LABELS = ["正式或性关系", "双向感情", "单向感情", "暧昧亲密", "非恋爱", "证据不足"]
ROMANTIC_LABELS = set(RELATION_LABELS[:4])
NEGATIVE_RELATION_LABELS = {"非恋爱", "证据不足"}
POSITIONS = [0.07, 0.23, 0.48, 0.72, 0.91]


@dataclass(frozen=True)
class RelationCase:
    case_id: str
    category: str
    expected: str
    protagonist: str
    candidate: str
    evidence: str


@dataclass(frozen=True)
class FactCase:
    case_id: str
    expected: str
    statement: str
    question: str
    position: float


def load_matrix_module():
    source = Path(__file__).with_name("run_matrix.py")
    spec = importlib.util.spec_from_file_location("edge_quant_matrix_quality", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def relation_cases() -> list[RelationCase]:
    names = [
        ("陆沉", "顾清禾", "周远"), ("谢临", "苏晚", "赵山"),
        ("陈野", "宁霜", "沈舟"), ("江渡", "白芷", "徐衡"),
        ("秦川", "叶红", "顾南"), ("林昼", "楚月", "贺平"),
        ("周砚", "柳青", "孟川"), ("许令", "红鸾", "唐明"),
    ]
    templates: dict[str, tuple[str, list[str]]] = {
        "formal": ("正式或性关系", [
            "{b}是{a}明媒正娶的妻子，两人已经成婚三年。",
            "{a}与{b}已经登记结婚，并公开以夫妻相称。",
            "{a}当众确认{b}是自己的恋人，两人正在正式交往。",
            "{a}和{b}在宗门见证下结为道侣。",
            "婚书已经交换，{b}是{a}确定的未婚妻。",
            "{b}明确说自己是{a}的女朋友，{a}也确认了关系。",
            "原文明写{a}与{b}昨夜发生了性关系。",
            "婚礼结束后，{a}与{b}正式结为夫妻。",
        ]),
        "mutual": ("双向感情", [
            "{b}喜欢{a}，{a}也承认自己喜欢{b}，但两人尚未交往。",
            "{b}向{a}告白，{a}回答我也爱你；他们还没有确定关系。",
            "{a}与{b}分别在信中写下对彼此的爱意，却都没有提出交往。",
            "{a}告诉{c}自己心悦{b}；同日{b}也向朋友承认心悦{a}。",
            "{a}和{b}都把对方称作心上人，仍未正式在一起。",
            "两人互诉爱意，确认彼此喜欢，但决定事情结束后再谈关系。",
            "{a}与{b}长期相互暗恋，今天终于承认了彼此的心意。",
            "{b}说只喜欢{a}，{a}也说自己的意中人一直是{b}。",
        ]),
        "unilateral": ("单向感情", [
            "{b}一直暗恋{a}，但{a}对此毫不知情。",
            "{a}喜欢{b}，{b}却只把{a}当作普通朋友。",
            "{b}向{a}告白后遭到明确拒绝。",
            "{b}爱着{a}，而{a}喜欢的人其实是{c}。",
            "{a}写给{b}的情书始终没有寄出，{b}不知道他的心意。",
            "{b}说自己爱{a}，{a}只回答我对你没有男女之情。",
            "所有人都知道{a}单相思{b}，只有{b}本人不知道。",
            "{b}承认对{a}动了心，旁白说明{a}从未喜欢过她。",
        ]),
        "ambiguous": ("暧昧亲密", [
            "{a}低头吻了{b}，事后两人都没有说明关系。",
            "{b}主动牵住{a}的手，红着脸一直没有松开。",
            "看见{a}与别人说笑，{b}明显吃醋，却否认自己喜欢他。",
            "{b}靠在{a}怀里睡了一夜，两人醒后避开了关系话题。",
            "{a}轻吻{b}的额头，双方没有告白，也没有确定关系。",
            "{b}替{a}整理衣领时贴得很近，两人同时脸红。",
            "{a}与{b}十指相扣走过长街，却仍对外声称只是同伴。",
            "{b}吻过{a}的脸颊，此后两人继续保持未说明的亲密状态。",
        ]),
        "non_romance": ("非恋爱", [
            "{b}是{a}失散多年的亲姐姐，两人终于相认。",
            "师父{b}抱起受伤的弟子{a}，把他送回房间疗伤。",
            "{a}与{b}是死敌，双方约定明日决一死战。",
            "医师{b}为{a}包扎伤口，并叮嘱病人按时服药。",
            "{a}和{b}参加了{c}的婚礼，{c}迎娶的是另一名女子。",
            "{b}从河里救起{a}，确认他没事后便独自离开。",
            "{a}喜欢{b}干脆的办事方式，旁白明确这只是欣赏能力。",
            "{a}与同事{b}完成交接后，各自回家陪伴自己的恋人。",
        ]),
        "insufficient": ("证据不足", [
            "{a}梦见自己与{b}成亲，醒来才知道是幻境。",
            "为了混进宴会，{b}临时假扮{a}的妻子。",
            "坊间传闻{a}喜欢{b}，但两名当事人都否认了传闻。",
            "旁人问{a}是不是喜欢{b}，{a}没有回答。",
            "{c}开玩笑说如果{a}和{b}成亲一定很热闹。",
            "舞台剧中{a}扮演丈夫、{b}扮演妻子，谢幕后角色关系结束。",
            "{b}希望将来能嫁给{a}，但原文没有说明现实感情。",
            "有人诬陷{a}与{b}私通，调查随后证明指控完全虚假。",
        ]),
    }
    rows: list[RelationCase] = []
    for category, (expected, phrases) in templates.items():
        for index, phrase in enumerate(phrases):
            protagonist, candidate, third = names[index]
            rows.append(RelationCase(
                case_id=f"rel-{category}-{index + 1:02d}",
                category=category,
                expected=expected,
                protagonist=protagonist,
                candidate=candidate,
                evidence=phrase.format(a=protagonist, b=candidate, c=third),
            ))
    return rows


def fact_cases() -> list[FactCase]:
    people = [
        "白砚", "顾遥", "陆迟", "周渡", "林鹤", "苏眠", "叶澄", "秦照",
        "谢岚", "楚宁", "沈越", "唐秋", "江栩", "宁川", "许棠", "孟舟",
        "温朔", "柳意", "韩青", "陈砚", "赵临", "方凝", "段星", "贺云",
    ]
    items = [
        "青铜钥匙", "赤纹地图", "黑檀木牌", "银色令牌", "琉璃药瓶", "玄铁短剑",
        "蓝封账册", "白玉印章", "紫金铃铛", "残缺阵盘", "鎏金书函", "乌木匣子",
        "星纹罗盘", "青瓷药罐", "旧城通行证", "火漆密信", "刻纹铜镜", "兽皮卷轴",
        "月白腰牌", "七孔骨笛", "暗红手札", "双鱼玉佩", "金线锦囊", "灰石棋子",
    ]
    places = [
        "北塔第三层", "南城旧井", "东仓暗格", "西院书房", "渡口石亭", "后山药庐",
        "钟楼地窖", "客栈天字房", "城主府密室", "竹林石碑下", "废寺佛像后", "矿洞岔路口",
        "藏书阁顶层", "河堤柳树下", "演武场兵器架", "码头七号仓", "雪岭哨站", "古墓前室",
        "茶楼二层", "王府马厩", "商会账房", "城南染坊", "湖心小岛", "驿站后院",
    ]
    rows: list[FactCase] = []
    for index in range(24):
        giver = people[(index + 7) % len(people)]
        receiver = people[index]
        item = items[index]
        rows.append(FactCase(
            case_id=f"fact-owner-{index + 1:02d}",
            expected=receiver,
            statement=f"行动结束前，{giver}把唯一的{item}交给{receiver}保管，其他人没有接触它。",
            question=f"{item}最后交给谁保管？",
            position=POSITIONS[index % len(POSITIONS)],
        ))
    for index in range(24):
        person = people[(index + 11) % len(people)]
        item = items[(index + 5) % len(items)]
        place = places[index]
        rows.append(FactCase(
            case_id=f"fact-place-{index + 1:02d}",
            expected=place,
            statement=f"无人跟踪时，{person}把{item}藏在{place}，随后抹去了脚印。",
            question=f"{person}把{item}藏在哪里？",
            position=POSITIONS[(index + 2) % len(POSITIONS)],
        ))
    for index in range(24):
        absent_item = f"未登记物品{index + 1:02d}号"
        rows.append(FactCase(
            case_id=f"fact-absent-{index + 1:02d}",
            expected="未提及",
            statement=f"值守记录只登记了{items[index]}，由{people[index]}放入{places[index]}。",
            question=f"记录中谁保管{absent_item}？",
            position=POSITIONS[(index + 4) % len(POSITIONS)],
        ))
    return rows


def filler_for(server, target_tokens: int = 6200) -> str:
    paragraph = (
        "巡夜人沿石板路走过庭院，依次记录风向、灯火、钟声和水位。"
        "完成这一页后，他合上册子，继续前往下一处院门。\n"
    )
    chunks: list[str] = []
    while server.tokenize("".join(chunks)) < target_tokens:
        chunks.append(paragraph)
    return "".join(chunks)


def insert_at(filler: str, evidence: str, position: float) -> str:
    paragraphs = filler.splitlines(keepends=True)
    index = min(len(paragraphs), max(0, int(len(paragraphs) * position)))
    paragraphs.insert(index, f"特别记录：{evidence}\n")
    return "".join(paragraphs)


def relation_prompt(case: RelationCase, context: str | None = None) -> str:
    evidence = case.evidence.replace(case.protagonist, "【主角】").replace(case.candidate, "【对象】")
    if context is None:
        body = f"待核验原文：\n1. {evidence}"
    else:
        body = f"以下是连续记录：\n{context}\n请只核验记录中的【主角】与【对象】。"
    return f"{body}\n/no_think"


def run_profile(matrix, engine_dir: Path, profile, round_index: int, log_dir: Path) -> dict[str, Any]:
    log = log_dir / f"quality-{profile.name}-round{round_index}.server.log"
    with matrix.Server(engine_dir, profile, 18839, log) as server:
        filler = filler_for(server)
        relations = relation_cases()
        facts = fact_cases()
        relation_rows: list[dict[str, Any]] = []
        for case in relations:
            response = server.chat(matrix.RELATION_SYSTEM, relation_prompt(case), 48, temperature=0.0)
            label = matrix.last_label(response["text"], RELATION_LABELS)
            relation_rows.append({
                "case_id": case.case_id, "scope": "short", "category": case.category,
                "expected": case.expected, "label": label, "correct": label == case.expected,
                "text": response["text"],
            })
        for index, case in sorted(enumerate(relations), key=lambda row: POSITIONS[row[0] % len(POSITIONS)]):
            position = POSITIONS[index % len(POSITIONS)]
            marked = case.evidence.replace(case.protagonist, "【主角】").replace(case.candidate, "【对象】")
            context = insert_at(filler, marked, position)
            response = server.chat(matrix.RELATION_SYSTEM, relation_prompt(case, context), 48, temperature=0.0)
            label = matrix.last_label(response["text"], RELATION_LABELS)
            relation_rows.append({
                "case_id": case.case_id, "scope": "long", "position": position,
                "category": case.category, "expected": case.expected, "label": label,
                "correct": label == case.expected,
                "text": response["text"],
            })

        fact_system = (
            "你是原文事实查询工具。只能依据给出的记录回答。记录未明确提供答案时必须回答“未提及”。"
            "最后一行只输出答案，不解释，不补充。"
        )
        fact_rows: list[dict[str, Any]] = []
        for case in sorted(facts, key=lambda row: row.position):
            context = insert_at(filler, case.statement, case.position)
            prompt = f"以下是按顺序保存的记录：\n{context}\n问题：{case.question}\n/no_think"
            response = server.chat(fact_system, prompt, 32, temperature=0.0)
            answer = matrix.cleaned(response["text"])
            correct = case.expected in answer
            fact_rows.append({
                "case_id": case.case_id, "position": case.position, "expected": case.expected,
                "answer": answer, "correct": correct,
                "hallucination": case.expected == "未提及" and "未提及" not in answer,
                "text": response["text"],
            })

    return {
        "profile": profile.name,
        "round": round_index,
        "relations": relation_rows,
        "facts": fact_rows,
    }


def metrics(run: dict[str, Any]) -> dict[str, Any]:
    short = [row for row in run["relations"] if row["scope"] == "short"]
    long = [row for row in run["relations"] if row["scope"] == "long"]
    high_risk = [
        row for row in run["relations"]
        if row["expected"] in NEGATIVE_RELATION_LABELS and row.get("label") in ROMANTIC_LABELS
    ]
    fact_hallucinations = [row for row in run["facts"] if row["hallucination"]]
    return {
        "short_relation_accuracy": sum(row["correct"] for row in short) / len(short),
        "long_relation_accuracy": sum(row["correct"] for row in long) / len(long),
        "fact_accuracy": sum(row["correct"] for row in run["facts"]) / len(run["facts"]),
        "negative_fact_accuracy": sum(row["correct"] for row in run["facts"] if row["expected"] == "未提及") / 24,
        "relationship_hallucinations": len(high_risk),
        "relationship_hallucination_ids": [f"{row['scope']}:{row['case_id']}" for row in high_risk],
        "fact_hallucinations": len(fact_hallucinations),
        "fact_hallucination_ids": [row["case_id"] for row in fact_hallucinations],
    }


def compare(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    base_rows = {
        f"{row['scope']}:{row['case_id']}": row for row in baseline["relations"]
    } | {f"fact:{row['case_id']}": row for row in baseline["facts"]}
    candidate_rows = {
        f"{row['scope']}:{row['case_id']}": row for row in candidate["relations"]
    } | {f"fact:{row['case_id']}": row for row in candidate["facts"]}
    regressions = [key for key in base_rows if base_rows[key]["correct"] and not candidate_rows[key]["correct"]]
    improvements = [key for key in base_rows if not base_rows[key]["correct"] and candidate_rows[key]["correct"]]
    disagreements = [
        key for key in base_rows
        if (base_rows[key].get("label") or base_rows[key].get("answer"))
        != (candidate_rows[key].get("label") or candidate_rows[key].get("answer"))
    ]
    base_metrics = metrics(baseline)
    candidate_metrics = metrics(candidate)
    new_relation_hallucinations = sorted(
        set(candidate_metrics["relationship_hallucination_ids"])
        - set(base_metrics["relationship_hallucination_ids"])
    )
    new_fact_hallucinations = sorted(
        set(candidate_metrics["fact_hallucination_ids"])
        - set(base_metrics["fact_hallucination_ids"])
    )
    return {
        "regressions": regressions,
        "improvements": improvements,
        "disagreements": disagreements,
        "new_relationship_hallucinations": new_relation_hallucinations,
        "new_fact_hallucinations": new_fact_hallucinations,
    }


def summary_report(payload: dict[str, Any]) -> str:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in payload["runs"]:
        grouped.setdefault(run["profile"], []).append(run)
    profiles = list(grouped)
    lines = [
        "# Q8 KV-cache expanded quality validation",
        "",
        f"Generated: {payload['generated_at']}",
        f"Rounds: {payload['rounds']}; cases per round/profile: 48 short relations + 48 long relations + 72 long facts = 168.",
        "Acceptance gate: no new hallucination cases and no labelled-suite accuracy drop greater than 3 percentage points. Speed is not evaluated.",
        "",
        "| Profile | Short relation | Long relation | Long fact | Negative fact | Relationship hallucinations | Fact hallucinations |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for profile in profiles:
        run_metrics = [metrics(run) for run in grouped[profile]]
        avg = lambda key: statistics.fmean(item[key] for item in run_metrics)
        lines.append(
            f"| {profile} | {avg('short_relation_accuracy'):.1%} | {avg('long_relation_accuracy'):.1%} | "
            f"{avg('fact_accuracy'):.1%} | {avg('negative_fact_accuracy'):.1%} | "
            f"{avg('relationship_hallucinations'):.1f} | {avg('fact_hallucinations'):.1f} |"
        )
    comparisons = [
        compare(grouped["q8_f16kv"][index], grouped["q8_q8kv"][index])
        for index in range(payload["rounds"])
    ]
    stable = all(comparisons[0] == item for item in comparisons[1:])
    first = comparisons[0]
    lines += [
        "",
        "## Candidate versus baseline",
        "",
        f"- Stable across rounds: {'yes' if stable else 'no'}.",
        f"- Regressions: {len(first['regressions'])}; improvements: {len(first['improvements'])}; output disagreements: {len(first['disagreements'])} / 168.",
        f"- New relationship hallucinations: {len(first['new_relationship_hallucinations'])}.",
        f"- New absent-fact hallucinations: {len(first['new_fact_hallucinations'])}.",
        "",
        "Regression IDs: " + (", ".join(first["regressions"]) or "none"),
        "",
        "New hallucination IDs: " + (
            ", ".join(first["new_relationship_hallucinations"] + first["new_fact_hallucinations"]) or "none"
        ),
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-dir", type=Path, required=True)
    parser.add_argument("--q8", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    matrix = load_matrix_module()
    profiles = [
        matrix.Profile("q8_f16kv", "Q8_0", args.q8.resolve(), "f16"),
        matrix.Profile("q8_q8kv", "Q8_0", args.q8.resolve(), "q8_0"),
    ]
    payload: dict[str, Any] = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "rounds": args.rounds,
        "runs": [],
    }
    args.out.mkdir(parents=True, exist_ok=True)
    for round_index in range(1, args.rounds + 1):
        for profile in profiles:
            print(f"round {round_index}/{args.rounds}: {profile.name}", flush=True)
            payload["runs"].append(
                run_profile(matrix, args.engine_dir.resolve(), profile, round_index, args.out)
            )
            (args.out / "results.partial.json").write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    (args.out / "results.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.out / "report.md").write_text(summary_report(payload), encoding="utf-8")
    print(args.out / "report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
