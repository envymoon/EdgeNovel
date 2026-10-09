"""Isolated, synthetic Chinese evidence-judgment probe; never touches app data."""

from __future__ import annotations

import argparse
import json
from collections import Counter

from any2jev.model import DecisionModel


CASES = [
    # id, trope, state, human label: direct / uncertain / irrelevant
    ("n01", "ntr", "主角林舟；妻子苏晚。原文：苏晚背着林舟与赵衡维持了两年恋情，亲口承认此事。", "direct"),
    ("n02", "ntr", "主角林舟；妻子苏晚。原文：林舟亲眼看到苏晚与赵衡拥吻，苏晚说自己已经爱上赵衡。", "direct"),
    ("n03", "ntr", "主角林舟；妻子苏晚。原文：苏晚仍与林舟保持婚姻关系，却同赵衡发生了性关系。", "direct"),
    ("n04", "ntr", "主角林舟；妻子苏晚。原文：苏晚与赵衡在旅馆过夜，第二天她称只是谈工作，林舟也不知道真相。", "uncertain"),
    ("n05", "ntr", "主角林舟；妻子苏晚。原文：街坊传言苏晚和赵衡私通，后来发现是邻居故意造谣。", "uncertain"),
    ("n06", "ntr", "主角林舟；妻子苏晚。原文：赵衡向苏晚表白，苏晚明确拒绝并告诉林舟。", "uncertain"),
    ("n07", "ntr", "主角林舟；妻子苏晚。原文：赵衡的妻子与旁人有染，赵衡愤怒地找人理论。", "irrelevant"),
    ("n08", "ntr", "主角林舟；妻子苏晚。原文：苏晚和林舟一起举办婚礼，赵衡作为普通宾客出席。", "irrelevant"),
    ("n09", "ntr", "主角林舟；妻子苏晚。原文：林舟读到一本小说，里面的男主被妻子背叛。", "irrelevant"),
    ("n10", "ntr", "主角林舟；妻子苏晚。原文：苏晚在嫁给林舟之前曾和赵衡交往，分手多年后才认识林舟。", "irrelevant"),
    ("n11", "ntr", "主角林舟；妻子苏晚。原文：苏晚笑着说自己爱上别人，随后解释是在排练一出戏。", "uncertain"),
    ("n12", "ntr", "主角林舟；妻子苏晚。原文：苏晚与赵衡暗中来往，信中写她已经变心，却未说明是否仍与林舟交往。", "uncertain"),
    ("c01", "chastity", "主角林舟；女主苏晚。原文：苏晚对林舟说，自己以前与前夫有过夫妻生活。", "direct"),
    ("c02", "chastity", "主角林舟；女主苏晚。原文：苏晚回忆多年前与前男友发生过性关系。", "direct"),
    ("c03", "chastity", "主角林舟；女主苏晚。原文：苏晚已经生过孩子，孩子的父亲是她前夫。", "direct"),
    ("c04", "chastity", "主角林舟；女主苏晚。原文：有人声称苏晚以前和别人有过关系，苏晚否认，双方没有证据。", "uncertain"),
    ("c05", "chastity", "主角林舟；女主苏晚。原文：苏晚与前男友曾经亲吻和拥抱，但原文没有描述更进一步。", "uncertain"),
    ("c06", "chastity", "主角林舟；女主苏晚。原文：苏晚说自己不是第一次恋爱。", "uncertain"),
    ("c07", "chastity", "主角林舟；女主苏晚。原文：苏晚的闺蜜陈月向林舟讲述自己与前男友的往事。", "irrelevant"),
    ("c08", "chastity", "主角林舟；女主苏晚。原文：林舟想起自己的前任，他们曾经同居。", "irrelevant"),
    ("c09", "chastity", "主角林舟；女主苏晚。原文：苏晚在书店看见一本讲婚姻问题的书。", "irrelevant"),
    ("c10", "chastity", "主角林舟；女主苏晚。原文：苏晚与林舟成婚后的第二天，两人一起吃早饭。", "irrelevant"),
    ("c11", "chastity", "主角林舟；女主苏晚。原文：苏晚说自己把第一次留给林舟；此句仅是人物自述。", "uncertain"),
    ("c12", "chastity", "主角林舟；女主苏晚。原文：苏晚在嫁给林舟前有一段婚约，但婚约很快解除。", "uncertain"),
]

LABELS = {
    "direct": "原文直接、明确支持这一雷点，且涉及指定主角或女主；不是传言、梦境或误会",
    "uncertain": "仅有相关线索或人物自述，尚不足以确定；或原文已否定相关传言",
    "irrelevant": "只涉及配角、小说中小说、无关事件，或发生在关系建立之前而不构成该雷点",
}


def judge(model: DecisionModel, trope: str, state: str, reverse: bool, binary: bool,
          english_labels: bool) -> dict:
    options = (
        [
            ("direct", "原文直接证明指定主角或女主发生该雷点；不是传言、误会或配角事件"),
            ("not_direct", "原文不构成该雷点的直接证据；包括传言、误会、证据不足和配角事件"),
        ]
        if binary
        else list(LABELS.items())
    )
    if english_labels:
        options = (
            [("direct", "Direct evidence about the named protagonist, not rumor or a side character"),
             ("not_direct", "Not direct evidence: rumor, ambiguity, negation, or a side character")]
            if binary else
            [("direct", "Direct evidence about the named protagonist, not rumor or misunderstanding"),
             ("uncertain", "Related but insufficient, ambiguous, or rumor"),
             ("irrelevant", "Unrelated, side character, fictional account, or before the relationship")]
        )
    if reverse:
        options.reverse()
    topic = "主角被伴侣背叛（绿帽/NTR）" if trope == "ntr" else "女主在认识主角前有过性关系（非处）"
    instruction = (
        f"Judge whether this Chinese fiction excerpt provides evidence of: {topic}."
        if english_labels else
        f"仅根据这段中文小说原文，判断它对“{topic}”的证据程度。"
    )
    request = {
        "state": state,
        "questions": {
            "evidence": {
                "type": "choice",
                "instructions": instruction,
                "criteria": dict(options),
            }
        },
    }
    answers, _ = model.decide(request)
    return answers["evidence"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--dtype", default="float32")
    parser.add_argument("--binary", action="store_true")
    parser.add_argument("--brief", action="store_true")
    parser.add_argument("--english-labels", action="store_true")
    args = parser.parse_args()
    model = DecisionModel.load(args.checkpoint, device=args.device, dtype=args.dtype)
    matrix = Counter()
    order_changes = 0
    results = []
    for case_id, trope, state, expected in CASES:
        expected = "direct" if expected == "direct" else "not_direct" if args.binary else expected
        forward = judge(model, trope, state, False, args.binary, args.english_labels)
        reversed_result = judge(model, trope, state, True, args.binary, args.english_labels)
        predicted = forward["choice"]
        matrix[(expected, predicted)] += 1
        order_changes += predicted != reversed_result["choice"]
        results.append({
            "id": case_id,
            "trope": trope,
            "expected": expected,
            "predicted": predicted,
            "probabilities": forward["probabilities"],
            "reversed_predicted": reversed_result["choice"],
        })
    print(json.dumps({
        "n": len(CASES),
        "accuracy": sum(row["expected"] == row["predicted"] for row in results) / len(CASES),
        "order_changes": order_changes,
        "confusion": [{"expected": a, "predicted": b, "count": n} for (a, b), n in sorted(matrix.items())],
        "results": [
            {"id": row["id"], "expected": row["expected"], "predicted": row["predicted"],
             "reversed_predicted": row["reversed_predicted"], "probabilities": row["probabilities"]}
            for row in results if not args.brief or row["expected"] != row["predicted"]
        ],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
