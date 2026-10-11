#!/usr/bin/env python3
"""Read screenshot pixels inside HarmonyOS UI-tree Web bounds; never edit inputs.

Requires Pillow (already provided by the Codex bundled Python on this workspace).
Examples:
  python tools/analyze-web-black.py layout.json screenshot.jpeg
  python tools/analyze-web-black.py layout.json screenshot.png --json
  python tools/analyze-web-black.py layout.json screenshot.jpeg --fail-on-black

Coordinates are screenshot pixels by default. For a deliberately resized full
screen screenshot, pass its original coordinate size with --tree-size WIDTHxHEIGHT.
A black candidate is evidence of a nearly black visible rectangle, not proof of
a rendering defect: a legitimate black image or dark Web page can look the same.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from typing import Any


Rect = tuple[float, float, float, float]
BOUNDS = re.compile(
    r"\[\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]"
    r"\[\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]"
)


def parse_bounds(value: Any) -> Rect | None:
    if not isinstance(value, str):
        return None
    match = BOUNDS.fullmatch(value.strip())
    if match is None:
        return None
    rect = tuple(float(part) for part in match.groups())
    return rect if all(math.isfinite(part) for part in rect) else None


def intersect(first: Rect, second: Rect) -> Rect:
    return (
        max(first[0], second[0]), max(first[1], second[1]),
        min(first[2], second[2]), min(first[3], second[3]),
    )


def boolean(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.lower() in ("true", "false"):
        return value.lower() == "true"
    return None


def invisible(attributes: dict[str, Any]) -> bool:
    if boolean(attributes.get("visible")) is False:
        return True
    try:
        return float(attributes.get("opacity", 1)) <= 0
    except (TypeError, ValueError):
        return False


def web_nodes(tree: Any) -> list[dict[str, Any]]:
    """Retain hidden Web nodes in the report, but never sample their rectangles."""
    result: list[dict[str, Any]] = []

    def visit(node: Any, path: str, clips: list[Rect], hidden: bool) -> None:
        if isinstance(node, list):
            for index, child in enumerate(node):
                visit(child, f"{path}[{index}]", clips, hidden)
            return
        if not isinstance(node, dict):
            return
        attributes = node.get("attributes", {})
        if not isinstance(attributes, dict):
            attributes = {}
        rect = parse_bounds(attributes.get("bounds"))
        hidden = hidden or invisible(attributes)
        if str(attributes.get("type", "")).lower() in ("web", "webview"):
            result.append({
                "path": path,
                "id": attributes.get("id", ""),
                "accessibility_id": attributes.get("accessibilityId", ""),
                "declared_background": attributes.get("backgroundColor", ""),
                "bounds": rect,
                "original_bounds": parse_bounds(attributes.get("origBounds")),
                "ancestor_clips": clips,
                "hidden": hidden,
            })
        if rect is not None and boolean(attributes.get("clip")) is True:
            clips = [*clips, rect]
        for index, child in enumerate(node.get("children", [])):
            visit(child, f"{path}.children[{index}]", clips, hidden)

    visit(tree, "root", [], False)
    return result


def analyze(tree: Any, screenshot: Any, *, near_black: int = 16,
            black_ratio: float = 0.98, min_area: int = 10000,
            min_edge: int = 32, tree_size: tuple[int, int] | None = None) -> dict[str, Any]:
    width, height = screenshot.size
    scale_x, scale_y = (1.0, 1.0)
    if tree_size is not None:
        scale_x, scale_y = width / tree_size[0], height / tree_size[1]
    canvas: Rect = (0, 0, width, height)
    warnings: list[str] = []
    root_bounds = parse_bounds(tree.get("attributes", {}).get("bounds")) if isinstance(tree, dict) else None
    if tree_size is None and root_bounds is not None and root_bounds != canvas:
        warnings.append(
            "UI root bounds differ from the screenshot canvas. Coordinates are used "
            "1:1; use --tree-size only for a deliberately resized full screen image."
        )
    rgba = screenshot.convert("RGBA")
    rows: list[dict[str, Any]] = []
    for node in web_nodes(tree):
        row = {key: value for key, value in node.items() if key not in ("ancestor_clips", "hidden")}
        row.update({
            "visible_tree_bounds": None, "sample_bounds": None, "sample_area": 0,
            "opaque_pixels": 0, "pure_black_pixels": 0, "near_black_pixels": 0,
            "pure_black_ratio": None, "near_black_ratio": None,
            "black_candidate": False, "status": "not-sampled",
        })
        rect = node["bounds"]
        if node["hidden"]:
            row["status"] = "hidden-node-or-ancestor"
        elif rect is None:
            row["status"] = "invalid-bounds"
        else:
            for clip in node["ancestor_clips"]:
                rect = intersect(rect, clip)
            row["visible_tree_bounds"] = rect
            scaled = (rect[0] * scale_x, rect[1] * scale_y, rect[2] * scale_x, rect[3] * scale_y)
            clipped = intersect(scaled, canvas)
            # Half-open image rectangles; no thumbnail dimensions or image writes.
            box = (math.floor(clipped[0]), math.floor(clipped[1]),
                   math.ceil(clipped[2]), math.ceil(clipped[3]))
            if box[2] <= box[0] or box[3] <= box[1]:
                row["status"] = "outside-visible-canvas"
            else:
                row["sample_bounds"] = box
                row["sample_area"] = (box[2] - box[0]) * (box[3] - box[1])
                data = rgba.crop(box).tobytes()
                opaque = pure = near = 0
                for offset in range(0, len(data), 4):
                    red, green, blue, alpha = data[offset:offset + 4]
                    if alpha == 0:
                        continue
                    opaque += 1
                    pure += red == 0 and green == 0 and blue == 0
                    near += max(red, green, blue) <= near_black
                row.update({"opaque_pixels": opaque, "pure_black_pixels": pure, "near_black_pixels": near})
                if opaque:
                    row["pure_black_ratio"] = pure / opaque
                    row["near_black_ratio"] = near / opaque
                sufficient = opaque >= min_area and min(box[2] - box[0], box[3] - box[1]) >= min_edge
                row["status"] = "sampled" if sufficient else "insufficient-visible-area"
                row["black_candidate"] = sufficient and near / opaque >= black_ratio
        rows.append(row)
    if not rows:
        warnings.append("No Web or WebView nodes found; this does not verify the rendered content.")
    return {
        "screenshot_size": [width, height], "ui_root_bounds": root_bounds,
        "coordinate_scale": [scale_x, scale_y],
        "thresholds": {"near_black_channel_max": near_black, "candidate_ratio": black_ratio,
                       "min_visible_pixels": min_area, "min_edge_pixels": min_edge},
        "web_count": len(rows), "black_candidate_count": sum(row["black_candidate"] for row in rows),
        "warnings": warnings, "web_regions": rows,
        "limitations": (
            "Pixel evidence only: legitimate black images and dark Web backgrounds may qualify. "
            "The UI tree and screenshot must be from the same stable frame. Occlusion by "
            "overlapping siblings, HTML element content and screenshot capture faults are not inferred. "
            "Bounds use ancestor clip intersections and the actual source image dimensions."
        ),
    }


def size_argument(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)[xX](\d+)", value)
    if match is None or min(int(part) for part in match.groups()) <= 0:
        raise argparse.ArgumentTypeError("expected positive WIDTHxHEIGHT")
    return tuple(int(part) for part in match.groups())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ui_tree", type=Path)
    parser.add_argument("screenshot", type=Path)
    parser.add_argument("--near-black", type=int, default=16, help="maximum R/G/B channel value (default: 16)")
    parser.add_argument("--black-ratio", type=float, default=0.98, help="candidate ratio (default: 0.98)")
    parser.add_argument("--min-area", type=int, default=10000, help="minimum visible nontransparent pixels")
    parser.add_argument("--min-edge", type=int, default=32, help="minimum visible width and height in pixels")
    parser.add_argument("--tree-size", type=size_argument, help="explicit original size for a resized full screen image")
    parser.add_argument("--json", action="store_true", help="emit the full machine-readable report")
    parser.add_argument("--fail-on-black", action="store_true", help="exit 1 when a sufficiently large black candidate exists")
    args = parser.parse_args()
    if not 0 <= args.near_black <= 255 or not 0 < args.black_ratio <= 1 or args.min_area <= 0 or args.min_edge <= 0:
        parser.error("thresholds must use channel 0..255, ratio (0,1], and positive area/edge")
    try:
        from PIL import Image
    except ImportError:
        parser.exit(2, "Pillow is unavailable in this Python. Use the already configured bundled Python; no installation is performed.\n")
    try:
        with args.ui_tree.open(encoding="utf-8-sig") as source:
            tree = json.load(source)
        with Image.open(args.screenshot) as screenshot:
            if screenshot.format not in ("JPEG", "PNG"):
                parser.error("expected a JPEG or PNG screenshot")
            report = analyze(tree, screenshot, near_black=args.near_black, black_ratio=args.black_ratio,
                             min_area=args.min_area, min_edge=args.min_edge, tree_size=args.tree_size)
    except (OSError, ValueError) as error:
        parser.exit(2, f"Cannot analyze inputs: {error}\n")
    report["inputs"] = {"ui_tree": str(args.ui_tree.resolve()), "screenshot": str(args.screenshot.resolve())}
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"Screenshot: {report['screenshot_size'][0]}x{report['screenshot_size'][1]} source pixels; scale={report['coordinate_scale']}")
        print(f"Web rectangles: {report['web_count']}; black candidates: {report['black_candidate_count']}")
        for index, row in enumerate(report["web_regions"], 1):
            pure = "n/a" if row["pure_black_ratio"] is None else f"{row['pure_black_ratio']:.4%}"
            near = "n/a" if row["near_black_ratio"] is None else f"{row['near_black_ratio']:.4%}"
            print(f"Web {index}: UI={row['bounds']}; sampled={row['sample_bounds']}; pixels={row['opaque_pixels']}; "
                  f"pure-black={pure}; near-black={near}; candidate={row['black_candidate']}; status={row['status']}")
        for warning in report["warnings"]:
            print(f"Warning: {warning}")
        print(f"Limits: {report['limitations']}")
    return 1 if args.fail_on_black and report["black_candidate_count"] else 0


if __name__ == "__main__":
    sys.exit(main())
