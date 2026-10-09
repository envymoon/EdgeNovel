"""Fast, model-free checks for the isolated runtime lab."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).with_name("measure.py")
SPEC = importlib.util.spec_from_file_location("edge_runtime_measure", SOURCE)
assert SPEC and SPEC.loader
measure = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = measure
SPEC.loader.exec_module(measure)


class CacheKeyTests(unittest.TestCase):
    def test_identical_request_hits_and_changed_input_misses(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            model = Path(root) / "model.gguf"
            model.write_bytes(b"model-v1")
            config = {"context": 8192, "kv": "q8_0", "ubatch": 512}
            original = {"messages": [{"role": "user", "content": "第一章"}], "temperature": 0.0}
            same_but_reordered = {"temperature": 0.0, "messages": [{"content": "第一章", "role": "user"}]}
            first = measure.cache_key(original, model, "engine-1", config)
            self.assertEqual(first, measure.cache_key(same_but_reordered, model, "engine-1", config))
            changed = {"messages": [{"role": "user", "content": "第二章"}], "temperature": 0.0}
            self.assertNotEqual(first, measure.cache_key(changed, model, "engine-1", config))
            self.assertNotEqual(first, measure.cache_key(original, model, "engine-2", config))
            self.assertNotEqual(first, measure.cache_key(original, model, "engine-1", {**config, "ubatch": 64}))
            model.write_bytes(b"model-v2-is-different")
            self.assertNotEqual(first, measure.cache_key(original, model, "engine-1", config))


if __name__ == "__main__":
    unittest.main()
