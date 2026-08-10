#!/usr/bin/env python3
"""Build the bundled civil-service practice bank from the verified four-column export."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ANSWER_PATTERN = re.compile(r"【答案】\s*([A-F]+)", re.IGNORECASE)
IMAGE_PATTERN = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
OPTION_PATTERN = re.compile(r"(?m)(?:^|[\r\n]|\s)([A-F])\s*[\.、．:]\s*")
TRAILING_REFERENCE_PATTERN = re.compile(
    r"\n(?:考点\d*|考点介绍|知识梳理|粉笔提示|决战真题|第[一二三四五六七八九十]+[章节部分]|【[^】]+】)",
    re.MULTILINE,
)

CATEGORY_IDS = {
    "政治理论与常识判断（公基）": "politics_and_common_sense",
    "言语理解与表达": "verbal_understanding",
    "数量关系": "quantitative_relations",
    "判断推理": "judgment_reasoning",
    "资料分析": "data_analysis",
}


def asset_token(value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        title, path = match.groups()
        normalized = path.removeprefix("./")
        if normalized.startswith("assets/"):
            normalized = normalized[len("assets/") :]
        return f"![{title}](civil-asset://{normalized})"

    return IMAGE_PATTERN.sub(replace, value)


def option_images(value: str) -> list[str]:
    paths = [path for _, path in IMAGE_PATTERN.findall(value)]
    if len(paths) not in (4, 5, 6):
        return []
    return [f"![选项图片](civil-asset://{path.removeprefix('./').removeprefix('assets/')})" for path in paths]


def best_option_group(value: str) -> list[tuple[re.Match[str], re.Match[str] | None]]:
    matches = list(OPTION_PATTERN.finditer(value))
    for start, match in enumerate(matches):
        if match.group(1).upper() != "A":
            continue
        group = [match]
        for entry in matches[start + 1 :]:
            expected = chr(65 + len(group))
            if entry.group(1).upper() != expected:
                break
            group.append(entry)
        if len(group) >= 4:
            return [
                (entry, matches[start + offset + 1] if start + offset + 1 < len(matches) else None)
                for offset, entry in enumerate(group)
            ]
    return []


def parse_options(value: str, minimum_label_count: int) -> list[dict[str, str]]:
    images = option_images(value)
    if images:
        return [
            {"label": chr(65 + index), "text": text}
            for index, text in enumerate(images)
        ]

    group = best_option_group(value)
    if group:
        output: list[dict[str, str]] = []
        for offset, (match, next_match) in enumerate(group):
            end = next_match.start() if next_match else len(value)
            text = value[match.end() : end].strip()
            if offset == len(group) - 1:
                marker = TRAILING_REFERENCE_PATTERN.search("\n" + text)
                if marker:
                    text = ("\n" + text)[: marker.start()].strip()
            output.append({"label": match.group(1).upper(), "text": asset_token(text)})
        if all(item["text"] for item in output):
            return output

    # Some source pages keep all four choices in a single combined image. The
    # four selectable labels remain explicit so the recorded answer is usable.
    return [
        {"label": chr(65 + index), "text": f"选项 {chr(65 + index)}（见题干或组合图片）"}
        for index in range(max(4, minimum_label_count))
    ]


def cleaned_explanation(value: str) -> str:
    value = re.sub(r"^\s*【答案】\s*[A-F]+\s*", "", value, count=1, flags=re.IGNORECASE)
    value = re.sub(r"^\s*【解析】\s*", "", value, count=1)
    return asset_token(value.strip())


def build(source: Path, output: Path) -> dict[str, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    counts = {category: 0 for category in CATEGORY_IDS}
    total = 0
    filtered_image_questions = 0
    with source.open("r", encoding="utf-8") as source_handle, output.open("w", encoding="utf-8") as output_handle:
        for line_number, line in enumerate(source_handle, 1):
            raw = json.loads(line)
            if any(
                IMAGE_PATTERN.search(value)
                for value in raw.values()
                if isinstance(value, str)
            ):
                filtered_image_questions += 1
                continue
            category, _, subcategory = raw["题型分类"].partition("｜")
            if category not in CATEGORY_IDS:
                raise ValueError(f"第 {line_number} 行包含未知分类：{category}")
            answer_match = ANSWER_PATTERN.search(raw["解析"])
            if not answer_match:
                raise ValueError(f"第 {line_number} 行没有明确答案")
            correct_labels = sorted(set(answer_match.group(1).upper()))
            minimum_label_count = max(ord(label) - 64 for label in correct_labels)
            options = parse_options(raw["选项"], minimum_label_count)
            available_labels = {item["label"] for item in options}
            if not set(correct_labels).issubset(available_labels):
                raise ValueError(f"第 {line_number} 行答案不在选项内：{correct_labels}")

            normalized_key = json.dumps(
                [category, raw["题干"], raw["选项"]], ensure_ascii=False, separators=(",", ":")
            )
            digest = hashlib.sha256(normalized_key.encode("utf-8")).hexdigest()[:20]
            stem = asset_token(raw["题干"].strip())
            represented_assets = {path for _, path in IMAGE_PATTERN.findall(stem)}
            for option in options:
                represented_assets.update(path for _, path in IMAGE_PATTERN.findall(option["text"]))
            missing_option_images = []
            for title, path in IMAGE_PATTERN.findall(asset_token(raw["选项"])):
                if path not in represented_assets:
                    missing_option_images.append(f"![{title}]({path})")
            if missing_option_images:
                stem += "\n\n【选项组合图片】\n" + "\n".join(missing_option_images)

            record = {
                "stable_id": f"gongkao-{CATEGORY_IDS[category]}-{digest}",
                "category": category,
                "subcategory": subcategory or "未细分",
                "stem": stem,
                "options": options,
                "correct_labels": correct_labels,
                "explanation": cleaned_explanation(raw["解析"]),
                "source": "manual-entry:xingce-v1",
            }
            output_handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            counts[category] += 1
            total += 1
    counts["总计"] = total
    counts["已过滤图片题"] = filtered_image_questions
    return counts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output), ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
