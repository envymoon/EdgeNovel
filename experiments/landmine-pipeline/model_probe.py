"""Isolated local Qwen3-0.6B sentence-judge screening; never changes app data.

The model is not given a whole-book task. It must classify a short, invented
passage after being told the protagonist, candidate heroine, and relationship
timing. A verdict is *not* integrated into the scanner unless independently
validated on real, manually labelled retrieval candidates.
"""

import argparse
import json
import re
import urllib.request


# A = direct, B = related but insufficient, C = unrelated.
CASES = [
    ("n1", "ntr", 20, "青灵背着高阳和王强偷情。", "A"),
    ("n2", "ntr", 20, "高阳撞见青翎和王强私通。", "A"),
    ("n3", "ntr", 20, "青灵背着高阳和李明发生关系。", "A"),
    ("n4", "ntr", 20, "青灵承认与王强偷情，向高阳道歉。", "A"),
    ("n5", "ntr", 5, "青灵背着高阳和王强偷情。", "B"),
    ("n6", "ntr", 20, "听说青灵背着高阳和王强偷情。", "B"),
    ("n7", "ntr", 20, "青灵梦见自己背着高阳和王强偷情。", "B"),
    ("n8", "ntr", 20, "青灵并没有背着高阳和王强偷情。", "B"),
    ("n9", "ntr", 20, "王强背着妻子小红和小兰偷情。", "C"),
    ("n10", "ntr", 20, "青灵看见王强背着小红和小兰偷情。", "C"),
    ("n11", "ntr", 20, "青灵和高阳已经圆房。", "C"),
    ("n12", "ntr", 20, "青灵离开帮派，被人视为对帮派的背叛。", "C"),
    ("p1", "past_relationship", 20, "青灵曾经与王强发生关系。", "A"),
    ("p2", "past_relationship", 20, "青翎在认识高阳之前曾与李明同房。", "A"),
    ("p3", "past_relationship", 20, "旁人传言青灵以前与王强发生关系。", "B"),
    ("p4", "past_relationship", 20, "青灵否认自己曾经与王强发生关系。", "B"),
    ("p5", "past_relationship", 20, "青灵说自己是处子。", "C"),
    ("p6", "past_relationship", 20, "青灵和高阳已经圆房。", "C"),
    ("p7", "past_relationship", 20, "王强曾经与小兰发生关系。", "C"),
    ("p8", "past_relationship", 20, "青灵喜欢王强。", "C"),
    ("r1", "progress", 20, "青灵和高阳确定关系。", "A"),
    ("r2", "progress", 20, "高阳与青翎正式交往。", "A"),
    ("r3", "progress", 20, "高阳还没和青灵成亲。", "B"),
    ("r4", "progress", 20, "青灵以为高阳已经坐船回去结婚了。", "C"),
]


def ask(endpoint: str, kind: str, chapter: int, sentence: str,
        *, reverse: bool = False, remap: bool = False) -> tuple[str, str]:
    labels = [("A", "直接证据：原文明确发生、人物与时间都符合"),
              ("B", "相关但不足：传闻、否认、梦境、未发生或关系时间不符"),
              ("C", "无关：不是这位女主的事件，或不属于此标签")]
    if remap:
        labels = [("C", labels[0][1]), ("B", labels[1][1]), ("A", labels[2][1])]
    if reverse:
        labels.reverse()
    task = {"ntr": "女主在与主角确认伴侣关系后与第三人发生的背叛",
            "past_relationship": "女主与非主角男性的过往明确性关系",
            "progress": "女主与主角的关系确认、成婚或明确性关系"}[kind]
    prompt = ("只判断下面这一句是否是该标签的证据，不推测全书。"
              "主角：高阳；女主候选：青灵（别名青翎）；两人从第11章才确认伴侣关系。"
              f"目标标签：{task}。当前第{chapter + 1}章。"
              "选项：" + "；".join(f"{code}={description}" for code, description in labels) + "。"
              f"原文：{sentence}\n只输出一个大写字母 A、B 或 C。")
    body = {"model": "local", "messages": [
        {"role": "system", "content": "你是严格的中文网文证据审查员。/no_think"},
        {"role": "user", "content": prompt}],
        "temperature": 0, "max_tokens": 32, "stream": False,
        "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(endpoint.rstrip("/") + "/v1/chat/completions",
                                     data=json.dumps(body, ensure_ascii=False).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=90) as response:
        answer = json.load(response)["choices"][0]["message"]["content"].strip()
    found = re.search(r"(?<![A-Z])[ABC](?![A-Z])", answer)
    return (found.group() if found else "?", answer)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True, help="already-running localhost llama-server")
    parser.add_argument("--limit", type=int, default=len(CASES))
    parser.add_argument("--show-raw", action="store_true")
    parser.add_argument("--remap", action="store_true", help="map direct to C and unrelated to A")
    args = parser.parse_args()
    rows = []
    for ident, kind, chapter, sentence, truth in CASES[:args.limit]:
        normal, normal_raw = ask(args.url, kind, chapter, sentence, remap=args.remap)
        reversed_order, reversed_raw = ask(args.url, kind, chapter, sentence, reverse=True,
                                          remap=args.remap)
        expected = {"A": "C", "C": "A", "B": "B"}[truth] if args.remap else truth
        rows.append({"id": ident, "truth": expected, "normal": normal,
                     "reversed": reversed_order,
                     **({"normal_raw": normal_raw, "reversed_raw": reversed_raw} if args.show_raw else {})})
        print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    print(json.dumps({"total": len(rows),
                      "correct": sum(r["normal"] == r["truth"] for r in rows),
                      "order_changed": sum(r["normal"] != r["reversed"] for r in rows),
                      "false_direct": sum(r["normal"] == ("C" if args.remap else "A")
                                          and r["truth"] != ("C" if args.remap else "A")
                                          for r in rows)},
                     ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
