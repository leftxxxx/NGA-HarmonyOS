#!/usr/bin/env python3
"""Small in-memory checks for the screenshot evidence tool; no device/image writes."""

import importlib.util
from pathlib import Path
import unittest

from PIL import Image


spec = importlib.util.spec_from_file_location("web_black", Path(__file__).with_name("analyze-web-black.py"))
web_black = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web_black)


def node(kind, bounds, children=None, **attributes):
    return {"attributes": {"type": kind, "bounds": bounds, **attributes}, "children": children or []}


class WebBlackEvidenceTests(unittest.TestCase):
    def test_visible_bounds_clip_to_ancestor_and_source_pixels(self):
        tree = node("root", "[0,0][1280,2832]", [
            node("List", "[100,600][1200,2700]", [
                node("Web", "[112,2207][1168,3985]", visible="true"),
            ], clip="true"),
        ])
        report = web_black.analyze(tree, Image.new("RGB", (1280, 2832), "black"))
        region = report["web_regions"][0]
        self.assertEqual(region["sample_bounds"], (112, 2207, 1168, 2700))
        self.assertEqual(region["sample_area"], 1056 * 493)
        self.assertTrue(region["black_candidate"])
        self.assertEqual(report["coordinate_scale"], [1, 1])

    def test_mixed_black_content_below_high_threshold_is_not_candidate(self):
        image = Image.new("RGB", (200, 200), "black")
        image.paste("white", (0, 0, 200, 6))  # 97% black, plausible content/background mixture.
        tree = node("root", "[0,0][200,200]", [node("Web", "[0,0][200,200]")])
        region = web_black.analyze(tree, image)["web_regions"][0]
        self.assertAlmostEqual(region["near_black_ratio"], 0.97)
        self.assertFalse(region["black_candidate"])

    def test_small_black_element_does_not_fail_visible_area_gate(self):
        tree = node("root", "[0,0][200,200]", [node("Web", "[0,0][40,40]")])
        region = web_black.analyze(tree, Image.new("RGB", (200, 200), "black"))["web_regions"][0]
        self.assertFalse(region["black_candidate"])
        self.assertEqual(region["status"], "insufficient-visible-area")

    def test_hidden_or_transparent_web_is_excluded(self):
        tree = node("root", "[0,0][200,200]", [
            node("Column", "[0,0][200,200]", [node("Web", "[0,0][200,200]")], visible="false"),
            node("Web", "[0,0][200,200]", opacity="0.000000"),
            node("Web", "[0,0][200,200]"),
        ])
        report = web_black.analyze(tree, Image.new("RGBA", (200, 200), (0, 0, 0, 0)))
        self.assertEqual(report["web_count"], 3)
        self.assertEqual(report["black_candidate_count"], 0)
        self.assertEqual(report["web_regions"][0]["status"], "hidden-node-or-ancestor")
        self.assertEqual(report["web_regions"][2]["opaque_pixels"], 0)

    def test_resizing_requires_explicit_original_tree_size(self):
        tree = node("root", "[0,0][400,600]", [node("Web", "[100,100][300,500]")])
        image = Image.new("RGB", (200, 300), "white")
        native = web_black.analyze(tree, image)
        scaled = web_black.analyze(tree, image, tree_size=(400, 600))
        self.assertEqual(native["web_regions"][0]["sample_bounds"], (100, 100, 200, 300))
        self.assertTrue(native["warnings"])
        self.assertEqual(scaled["web_regions"][0]["sample_bounds"], (50, 50, 150, 250))
        self.assertEqual(scaled["coordinate_scale"], [0.5, 0.5])

    def test_system_dark_background_without_web_nodes_is_not_sampled(self):
        tree = node("root", "[0,0][200,200]", [node("StatusBar", "[0,0][200,40]")])
        report = web_black.analyze(tree, Image.new("RGB", (200, 200), "black"))
        self.assertEqual(report["web_count"], 0)
        self.assertEqual(report["black_candidate_count"], 0)
        self.assertTrue(report["warnings"])


if __name__ == "__main__":
    unittest.main()
