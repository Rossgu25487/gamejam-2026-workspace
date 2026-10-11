#!/usr/bin/env python3
"""只读导入《声音播放系统配置表》。

规则（对应配置表“_填写说明”与配套说明第 1-6 节）：
- 前 4 行为 ##comment / ##var / ##type / ##group，第 5 行起一行一条记录；
- 以下划线开头的页为说明或候选样例，不导出；
- A 列为 ## 的行是测试或注释行：不进入正式导出，仅整理成测试夹具；
- 正式资源允许两个引用字段都为空（用途已定、素材未采用），此时运行时视为“未绑定”，不发声；
- 数值保留真实类型，范围与集合约束按 ##type 校验，违规即失败。

输出：
- game/data/audio/audio_config.json        正式配置（总控、资源、事件、音景）
- game/tests/fixtures/audio/audio_ex_config.json  EX 技术测试资源与音景

只依赖标准库，完成后直接退出。--check 仅比对磁盘文件是否与配置表一致。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_core_config import read_tables  # noqa: E402  复用只读 XLSX 解析

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "game" / "代码开发需求" / "声音播放系统" / "声音播放系统配置表.xlsx"
FORMAL_OUT = ROOT / "game" / "data" / "audio" / "audio_config.json"
FIXTURE_OUT = ROOT / "game" / "tests" / "fixtures" / "audio" / "audio_ex_config.json"

SHEET_CONTROL = "声音总控"
SHEET_RESOURCE = "声音资源"
SHEET_EVENT = "声音事件"
SHEET_SOUNDSCAPE = "场景音景"

ID_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


class ImportFailure(Exception):
    """配置表内容不满足约束。"""


def parse_type(spec: str) -> dict:
    """解析 ##type，例如 string!、int#range=[0,5000]、string#(set=a,b)、string#ref=x.Y?。"""
    base, _, constraint = spec.partition("#")
    info = {"base": base.rstrip("!?").strip() or "string", "required": base.endswith("!")}
    if constraint.startswith("range="):
        low, high = constraint[len("range="):].strip("[]").split(",")
        info["range"] = (float(low), float(high))
    elif constraint.startswith("(set=") or constraint.startswith("set="):
        info["set"] = [x.strip() for x in constraint.split("=", 1)[1].rstrip(")").split(",")]
    elif constraint.startswith("ref="):
        info["ref"] = constraint[len("ref="):]
    return info


def convert(raw: str, spec: str, where: str):
    """按 ##type 转换单元格；空串对非字符串类型返回 None 由调用方决定是否合法。"""
    info = parse_type(spec)
    base = info["base"]
    if raw == "":
        return "" if base == "string" else None
    if base in ("int", "long"):
        number = float(raw)
        if number != int(number):
            raise ImportFailure("%s：整数字段出现小数 %r" % (where, raw))
        value = int(number)
    elif base in ("float", "double"):
        value = float(raw)
    elif base == "bool":
        lowered = raw.strip().lower()
        if lowered not in ("1", "0", "true", "false"):
            raise ImportFailure("%s：非法布尔值 %r" % (where, raw))
        value = lowered in ("1", "true")
    else:
        value = raw
    if "range" in info and not (info["range"][0] <= value <= info["range"][1]):
        raise ImportFailure("%s：%r 超出范围 %s" % (where, value, info["range"]))
    if "set" in info and value not in info["set"]:
        raise ImportFailure("%s：%r 不在集合 %s 中" % (where, value, info["set"]))
    return value


def read_sheet(rows: list[dict], sheet: str) -> list[tuple[str, dict]]:
    """返回 [(A 列标记, 记录)]。注释行的非法字段在这里不报错，交给调用方判断其是否为记录。"""
    if len(rows) < 4 or rows[1].get("A") != "##var":
        raise ImportFailure("%s：缺少 ##var 表头" % sheet)
    names = {col: key for col, key in rows[1].items() if col != "A" and key and not key.startswith("#")}
    kinds = {col: rows[2].get(col, "string") for col in names}
    result: list[tuple[str, dict]] = []
    for index, row in enumerate(rows[4:], start=5):
        marker = row.get("A", "")
        record: dict = {}
        failure = None
        for col, key in names.items():
            try:
                record[key] = convert(row.get(col, ""), kinds[col], "%s 第%d行 %s" % (sheet, index, key))
            except (ImportFailure, ValueError) as error:
                failure = failure or error
                record[key] = None
        if failure is not None:
            if marker == "":
                raise ImportFailure(str(failure))
            continue  # 测试或注释行里无法解析的内容整行视为说明文字
        if all(value in ("", None) for value in record.values()):
            continue  # 空行
        result.append((marker, record))
    return result


def is_record(record: dict, required: list[str]) -> bool:
    """A 列为 ## 的行，只有具备合法稳定 id 且必填字段齐全时才算测试记录，否则视为说明文字。"""
    identity = record.get("id")
    if not isinstance(identity, str) or not ID_PATTERN.match(identity):
        return False
    return all(record.get(key) not in ("", None) for key in required)


def split_rows(pairs: list[tuple[str, dict]], required: list[str]) -> tuple[list[dict], list[dict]]:
    formal: list[dict] = []
    tests: list[dict] = []
    for marker, record in pairs:
        if marker == "":
            for key in required:
                if record.get(key) in ("", None):
                    raise ImportFailure("正式记录 %s 缺少必填字段 %s" % (record.get("id"), key))
            formal.append(record)
        elif marker == "##" and is_record(record, required):
            tests.append(record)
    return formal, tests


def ensure_unique(records: list[dict], key_fields: list[str], label: str) -> None:
    seen = set()
    for record in records:
        key = tuple(record.get(field, "") for field in key_fields)
        if key in seen:
            raise ImportFailure("%s 出现重复键 %s" % (label, key))
        seen.add(key)


def validate(control: dict, resources: list[dict], events: list[dict], soundscapes: list[dict]) -> None:
    by_id = {r["id"]: r for r in resources}
    ensure_unique(resources, ["id"], "声音资源")
    ensure_unique(events, ["id"], "声音事件")
    ensure_unique(soundscapes, ["id"], "场景音景")
    ensure_unique(soundscapes, ["context_kind", "target_ref", "phase_ref"], "场景音景(上下文+目标+阶段)")
    for record in resources:
        if record.get("resource_ref") and record.get("resource_path"):
            raise ImportFailure("资源 %s 不能同时填写 resource_ref 与 resource_path" % record["id"])
    for event in events:
        key = event.get("resource_key", "")
        if event["source_kind"] == "fixed":
            if key not in by_id:
                raise ImportFailure("事件 %s 引用了不存在的固定资源 %r" % (event["id"], key))
            if by_id[key]["bus"] != event["bus"]:
                raise ImportFailure("事件 %s 与其固定资源 %s 的类别不一致" % (event["id"], key))
        elif key:
            raise ImportFailure("动态事件 %s 的 resource_key 必须留空" % event["id"])
    for scape in soundscapes:
        if scape["context_kind"] in ("scene", "ending") and not scape.get("target_ref"):
            raise ImportFailure("音景 %s 缺少 target_ref" % scape["id"])
        for field, bus in (("bgm_key", "bgm"), ("ambient_key", "ambient")):
            key = scape.get(field, "")
            if key and (key not in by_id or by_id[key]["bus"] != bus):
                raise ImportFailure("音景 %s 的 %s 必须引用类别为 %s 的资源" % (scape["id"], field, bus))
    if control["id"] != "default":
        raise ImportFailure("声音总控只允许 id=default")


def clean(record: dict) -> dict:
    """去掉空值之外的内部字段，保持稳定键序。"""
    return {key: value for key, value in record.items() if value is not None}


def build() -> tuple[dict, dict]:
    tables = read_tables(SOURCE)
    # 声音总控：只保留一条正式记录
    control_pairs = read_sheet(tables[SHEET_CONTROL], SHEET_CONTROL)
    control_rows, _ = split_rows(control_pairs, ["id", "bgm_crossfade_ms", "ambient_fade_ms", "menu_bgm_factor"])
    if len(control_rows) != 1:
        raise ImportFailure("声音总控必须恰有 1 条正式记录，实际 %d 条" % len(control_rows))
    control = clean(control_rows[0])

    resources, ex_resources = split_rows(read_sheet(tables[SHEET_RESOURCE], SHEET_RESOURCE), ["id", "bus"])
    events, _ = split_rows(
        read_sheet(tables[SHEET_EVENT], SHEET_EVENT),
        ["id", "bus", "source_kind", "loop", "event_gain"],
    )
    soundscapes, ex_soundscapes = split_rows(
        read_sheet(tables[SHEET_SOUNDSCAPE], SHEET_SOUNDSCAPE),
        ["id", "context_kind"],
    )

    # 正式配置与“正式+EX 联合”分别校验：EX 音景引用的资源也在 EX 资源行里
    validate(control, resources, events, soundscapes)
    validate(control, resources + ex_resources, events, soundscapes + ex_soundscapes)

    formal = {
        "schema": 1,
        "control": control,
        "resources": [clean(r) for r in resources],
        "events": [clean(e) for e in events],
        "soundscapes": [clean(s) for s in soundscapes],
    }
    fixture = {
        "schema": 1,
        "note": "技术测试配置：EX 行来自配置表 A 列 ##，不进入正式导出；资源路径相对测试资源根目录。",
        "resources": [clean(r) for r in ex_resources],
        "soundscapes": [clean(s) for s in ex_soundscapes],
    }
    return formal, fixture


def render(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="导入声音播放系统配置表")
    parser.add_argument("--check", action="store_true", help="只比对磁盘文件是否与配置表一致，不写入")
    args = parser.parse_args()
    try:
        formal, fixture = build()
    except ImportFailure as error:
        print("导入失败：%s" % error, file=sys.stderr)
        return 1
    outputs = [(FORMAL_OUT, render(formal)), (FIXTURE_OUT, render(fixture))]
    if args.check:
        stale = [str(path) for path, text in outputs if not path.exists() or path.read_text(encoding="utf-8") != text]
        if stale:
            print("以下文件与配置表不一致：\n  " + "\n  ".join(stale), file=sys.stderr)
            return 1
        print("音频配置与配置表一致。")
        return 0
    for path, text in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(
        "已导入 声音总控1条、资源%d条、事件%d条、正式音景%d条；EX资源%d条、EX音景%d条仅写入测试夹具。"
        % (
            len(formal["resources"]),
            len(formal["events"]),
            len(formal["soundscapes"]),
            len(fixture["resources"]),
            len(fixture["soundscapes"]),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
