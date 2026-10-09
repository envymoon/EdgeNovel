"""Small, adversarial fixtures. They are not a real-book accuracy estimate."""

import unittest

from probe import Chain, Finding, Heroine, Passage, aggregate_findings, chain_from_cast, decoded_utf8, findings_around, infer_relationship_timeline, recall, verify_event


CHAIN = Chain(("高阳",), (Heroine(("青灵", "青翎"), 10, "已确认伴侣"),))
POSSIBLE = Chain(("高阳",), (Heroine(("青灵", "青翎"), None, "持续暧昧关系"),))


class VerifyTests(unittest.TestCase):
    def check(self, kind, text, expected, chapter=20, chain=CHAIN, context=""):
        found = verify_event(Passage(chapter, 0, len(text.encode()), text), chain, kind, context=context)
        self.assertEqual(found.verdict, expected, (kind, text, found))
        if found.verdict == "explicit":
            self.assertIn(found.evidence, text)

    def test_ntr_temporal_roles_and_uncertainty(self):
        cases = [
            ("青灵背着高阳和王强偷情。", "explicit", 20, CHAIN),
            ("高阳撞见青翎和王强私通。", "explicit", 20, CHAIN),
            ("青灵背着高阳和王强偷情。", "clue", 5, CHAIN),
            ("青灵背着高阳和王强偷情。", "clue", 20, POSSIBLE),
            ("据说青灵背着高阳和王强偷情。", "clue", 20, CHAIN),
            ("青灵并没有背着高阳和王强偷情。", "clue", 20, CHAIN),
            ("青灵梦见自己背着高阳和王强偷情。", "clue", 20, CHAIN),
            ("王强背着妻子小红和青灵偷情。", "clue", 20, CHAIN),
            ("王强背着妻子小红和小兰偷情。", "unrelated", 20, CHAIN),
            ("青灵把偷情的谣言讲给高阳听。", "clue", 20, CHAIN),
            ("青灵离开帮派代表崔家的背叛。", "unrelated", 20, CHAIN),
        ]
        for text, label, chapter, chain in cases:
            with self.subTest(text=text):
                self.check("ntr", text, label, chapter, chain)

    def test_past_relationship_not_inferred_from_flirting(self):
        cases = [
            ("青灵曾经与王强发生关系。", "explicit"),
            ("青翎以前和王强同房。", "explicit"),
            ("青灵以前与高阳发生关系。", "unrelated"),
            ("据说青灵曾经与王强发生关系。", "clue"),
            ("青灵否认自己曾经与王强发生关系。", "clue"),
            ("青灵说自己是处子。", "unrelated"),
            ("青灵和高阳已经圆房。", "unrelated"),
            ("青灵喜欢王强。", "unrelated"),
            ("王强曾经与小兰发生关系。", "unrelated"),
            ("她曾经与王强发生关系。", "unbound"),
        ]
        for text, label in cases:
            with self.subTest(text=text):
                self.check("past_relationship", text, label, context="青灵站在门外。")

    def test_progress_is_tied_to_both_people(self):
        cases = [
            ("青灵和高阳确定关系。", "explicit"),
            ("高阳与青翎正式交往。", "explicit"),
            ("青灵和王强结婚。", "unrelated"),
            ("青灵以为高阳已经坐船回去结婚了。", "unrelated"),
            ("高阳还没和青灵成亲。", "clue"),
            ("据说青灵和高阳结婚。", "clue"),
            ("青灵没有和高阳结婚。", "clue"),
            ("小兰和王强结婚。", "unrelated"),
        ]
        for text, label in cases:
            with self.subTest(text=text):
                self.check("progress", text, label)

    def test_same_chunk_identity_is_not_transferred_between_sentences(self):
        self.check("ntr", "青灵正在做饭。王强背着妻子小红和小兰偷情。", "unrelated")

    def test_later_sentence_is_not_hidden_by_earlier_keyword(self):
        text = "王强背着小红和小兰偷情。青灵背着高阳和李明私通。"
        result = verify_event(Passage(20, 100, 100 + len(text.encode()), text), CHAIN, "ntr")
        self.assertEqual(result.verdict, "explicit")
        self.assertEqual(result.evidence, "青灵背着高阳和李明私通。")
        self.assertEqual(result.start, 100 + len("王强背着小红和小兰偷情。".encode()))

    def test_adjacent_chunk_finds_event_without_misassigning_it(self):
        first = Passage(20, 0, 20, "青灵和高阳走进屋里。")
        second = Passage(20, 20, 50, "青灵背着高阳和王强偷情。")
        third = Passage(21, 50, 80, "小兰和王强私通。")
        found = findings_around([first, second, third], 0, CHAIN, "ntr")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].verdict, "explicit")
        self.assertEqual(found[0].chapter, 20)

    def test_multiple_heroines_in_one_sentence_are_not_arbitrarily_assigned(self):
        chain = Chain(("高阳",), (Heroine(("青灵",), 10, "已确认"),
                               Heroine(("小兰",), 10, "已确认")))
        found = verify_event(Passage(20, 0, 60, "青灵听说小兰背着高阳和王强偷情。"), chain, "ntr")
        self.assertEqual(found.verdict, "unbound")

    def test_relationship_json_keeps_possible_but_not_confirmed(self):
        cast = {
            "people": [{"name": "高阳", "aliases": []}],
            "relationship": {
                "protagonist": "高阳",
                "people": [{"name": "青灵 / 青翎", "possible": True, "confirmed": False,
                            "status": "持续暧昧关系", "evidence": []}],
            },
        }
        chain = chain_from_cast(cast)
        self.assertEqual(chain.heroines[0].names, ("青灵", "青翎"))
        self.assertIsNone(chain.heroines[0].confirmed_from)

    def test_cast_sex_label_alone_does_not_prove_relationship_start(self):
        cast = {"people": [{"name": "高阳"}],
                "relationship": {"protagonist": "高阳", "people": [
                    {"name": "青灵", "confirmed": True, "status": "已确认伴侣",
                     "evidence": [{"chapter": 10, "kind": "性关系",
                                   "text": "青灵和高阳同床共枕。"}]}]}}
        self.assertIsNone(chain_from_cast(cast).heroines[0].confirmed_from)

    def test_cached_explicit_label_from_future_marriage_is_not_trusted(self):
        cast = {"people": [{"name": "高阳"}],
                "relationship": {"protagonist": "高阳", "people": [
                    {"name": "青灵", "confirmed": True, "status": "已确认伴侣",
                     "evidence": [{"chapter": 10, "kind": "明确关系",
                                   "text": "等高阳和青灵结婚，大家会开心。"}]}]}}
        chain = chain_from_cast(cast)
        self.assertIsNone(chain.heroines[0].confirmed_from)
        rows = [Passage(10, 0, 50, "等高阳和青灵结婚，大家会开心。"),
                Passage(20, 50, 100, "高阳和青灵确定关系。")]
        self.assertEqual(infer_relationship_timeline(rows, chain).heroines[0].confirmed_from, 20)

    def test_recall_adds_event_and_role_channels_across_segments(self):
        rows = [
            Passage(1, 0, 1, "别处的出轨传闻。"),
            Passage(2, 2, 3, "青灵与高阳同行。"),
            Passage(105, 4, 5, "青灵背着高阳和王强偷情。"),
            Passage(210, 6, 7, "青翎跟高阳一起出门。"),
        ]
        chosen = recall(rows, CHAIN, "ntr", segment_size=100, per_segment=1)
        self.assertEqual([r.chapter for r, _ in chosen], [2, 105, 210])
        self.assertIn("event+heroine", chosen[1][1])

    def test_semantic_channel_is_union_not_a_filter(self):
        rows = [Passage(1, 0, 1, "无关键词的场景。")]
        chosen = recall(rows, CHAIN, "ntr", semantic=rows)
        self.assertEqual(chosen[0][1], {"semantic"})

    def test_extra_quota_never_evicts_legacy_semantic_hit(self):
        rows = [
            Passage(1, 0, 1, "青灵背着高阳和王强偷情。"),
            Passage(2, 2, 3, "无关键词的原有语义命中。"),
        ]
        chosen = recall(rows, CHAIN, "ntr", semantic=[rows[1]], per_segment=1)
        self.assertEqual([r.chapter for r, _ in chosen], [2, 1])

    def test_report_keeps_absence_uncertain_and_deduplicates_one_chapter(self):
        no_hits = aggregate_findings([], CHAIN, 100, {0, 1})[0]
        self.assertIn("不等于不存在", no_hits["report"])
        self.assertEqual(no_hits["coverage"], "2/100 章")
        finding = Finding("progress", "explicit", "青灵", 20, 100,
                          "青灵和高阳确定关系。", "原文", "确认关系")
        report = aggregate_findings([finding, finding], CHAIN, 100, set(range(100)))[0]
        self.assertEqual(report["explicit_events"], 1)
        self.assertEqual(report["milestones"], {"确认关系": 21})

    def test_gbk_and_crlf_offsets_are_normalized_before_snippets(self):
        raw = "青灵\r\n高阳".encode("gbk")
        self.assertEqual(decoded_utf8(raw, "GBK"), "青灵\n高阳".encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
