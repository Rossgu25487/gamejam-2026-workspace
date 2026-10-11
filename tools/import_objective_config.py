#!/usr/bin/env python3
"""只读导入《目标导航系统配置表》。

配置表各页第 4 行为表头、第 5 行起为数据（见《目标导航系统说明》第 1 节）；
数值与坐标数组按“类型”列转换，违规即失败。

输出：
- game/data/objective/objective_config.json                        HUD 与回顾显示初值、功能文字键
- game/tests/fixtures/objective/objective_test_data.json            TEST00-TEST10 测试组、依据与 EX01-EX26 测试操作

正式剧情为 0 条接入；测试数据只供测试与试玩台使用。
只依赖标准库，完成后直接退出。--check 仅比对磁盘文件是否与配置表一致。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_core_config import read_tables  # noqa: E402  复用只读 XLSX 解析

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "game" / "代码开发需求" / "目标导航系统" / "目标导航系统配置表.xlsx"
CONFIG_OUT = ROOT / "game" / "data" / "objective" / "objective_config.json"
TEST_OUT = ROOT / "game" / "tests" / "fixtures" / "objective" / "objective_test_data.json"

HEADERS = {
    "组件参数": "配置键",
    "功能文字引用": "位置键",
    "测试目标": "测试组ID",
    "测试事项": "测试组ID",
    "测试依据": "依据ID",
    "测试操作": "测试编号",
}


class ImportFailure(Exception):
    """配置表内容不满足约束。"""


def sheet_records(tables: dict, name: str) -> list[dict]:
    """按表头文字返回记录；表头行之前的标题与说明行忽略，空行跳过。"""
    rows = tables.get(name)
    if rows is None:
        raise ImportFailure("缺少页签：" + name)
    first = HEADERS[name]
    header_at = next((i for i, row in enumerate(rows) if row.get("A") == first), None)
    if header_at is None:
        raise ImportFailure("%s：找不到表头“%s”" % (name, first))
    header = rows[header_at]
    records = []
    for row in rows[header_at + 1:]:
        record = {header[col]: row.get(col, "") for col in header if header[col]}
        if all(value == "" for value in record.values()):
            continue
        records.append(record)
    return records


def to_bool(raw: str, where: str) -> bool:
    lowered = str(raw).strip().lower()
    if lowered not in ("1", "0", "true", "false"):
        raise ImportFailure("%s：非法布尔值 %r" % (where, raw))
    return lowered in ("1", "true")


def to_typed(raw: str, kind: str, where: str):
    if kind == "int":
        number = float(raw)
        if number != int(number):
            raise ImportFailure("%s：整数字段出现小数 %r" % (where, raw))
        return int(number)
    if kind == "float":
        return float(raw)
    if kind == "bool":
        return to_bool(raw, where)
    if kind == "int[]":
        value = json.loads(raw)
        if not isinstance(value, list) or not all(isinstance(x, int) for x in value):
            raise ImportFailure("%s：数组格式错误 %r" % (where, raw))
        return value
    return raw


def build_config(tables: dict) -> dict:
    hud: dict = {}
    review: dict = {}
    for record in sheet_records(tables, "组件参数"):
        key = record["配置键"]
        value = to_typed(record["初值"], record["类型"], "组件参数 " + key)
        if key.startswith("review_"):
            review[key[len("review_"):]] = value
        else:
            hud[key] = value
    texts = {}
    for record in sheet_records(tables, "功能文字引用"):
        if not record["统一文字键"].startswith("UI_"):
            raise ImportFailure("功能文字引用 %s：文字键格式错误" % record["位置键"])
        texts[record["位置键"]] = record["统一文字键"]
    for key in ("update_notice_ms", "update_glow_ms", "visible_item_limit", "base_panel_rect", "compact_panel_rect"):
        if key not in hud:
            raise ImportFailure("组件参数缺少 " + key)
    for key in ("viewport", "main_rect", "pending_rect", "progress_rect"):
        if key not in review:
            raise ImportFailure("回顾参数缺少 review_" + key)
    return {"schema": 1, "hud": hud, "review": review, "texts": texts}


def split_ids(raw: str) -> list[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def build_test_data(tables: dict) -> dict:
    bases: dict = {}
    for record in sheet_records(tables, "测试依据"):
        bases[record["依据ID"]] = {
            "id": record["依据ID"],
            "kind": record["类型"],
            "object_id": record["对象ID"],
            "version_id": record["准确版本ID"],
            "version_text": record["版本显示文字"],
            "session_id": record["实际会话ID"],
            "name": record["名称或署名"],
            "body": record["测试正文"],
            "source_id": record["来源依据ID"],
        }
    groups: dict = {}
    for record in sheet_records(tables, "测试目标"):
        group_id = record["测试组ID"]
        groups[group_id] = {
            "goal_id": record["目标ID"],
            "goal_text": record["主目标全文"],
            "origin": record["刷新来源"],
            "display_allowed": to_bool(record["允许场景显示"], group_id + " 允许场景显示"),
            "reduce_motion": to_bool(record["减弱动态"], group_id + " 减弱动态"),
            "paused": to_bool(record["暂停计时"], group_id + " 暂停计时"),
            "items": [],
        }
        if groups[group_id]["origin"] not in ("initial", "result", "restore"):
            raise ImportFailure("%s：刷新来源无效" % group_id)
    for record in sheet_records(tables, "测试事项"):
        group_id = record["测试组ID"]
        if group_id not in groups:
            raise ImportFailure("测试事项引用了不存在的测试组 " + group_id)
        if record["进展"] not in ("pending", "checked"):
            raise ImportFailure("%s/%s：进展必须为 pending 或 checked" % (group_id, record["事项ID"]))
        refs = split_ids(record["准确依据ID"])
        for ref in refs:
            if ref not in bases:
                raise ImportFailure("%s/%s：依据 %s 不存在" % (group_id, record["事项ID"], ref))
        item = {
            "id": record["事项ID"],
            "order": int(float(record["显示顺序"])),
            "text": record["事项全文"],
            "status": record["进展"],
            "reason": record["已公开原因"],
            "basis": refs,
        }
        if record["调查入口ID"]:
            item["entry"] = {
                "id": record["调查入口ID"],
                "available": to_bool(record["入口可用"], "%s/%s 入口可用" % (group_id, record["事项ID"])),
                "reason": record["入口公开原因"],
            }
        groups[group_id]["items"].append(item)
    for group_id, group in groups.items():
        orders = [item["order"] for item in group["items"]]
        if len(set(orders)) != len(orders):
            raise ImportFailure("%s：显示顺序重复" % group_id)
    for base in bases.values():
        if base["source_id"] and base["source_id"] not in bases:
            raise ImportFailure("依据 %s 的来源 %s 不存在" % (base["id"], base["source_id"]))
    operations = []
    for record in sheet_records(tables, "测试操作"):
        operations.append({
            "id": record["测试编号"],
            "groups": [part.strip() for part in record["输入测试组"].split("→") if part.strip()],
            "operation": record["操作与提供方结果"],
            "expected": record["预期显示或输出"],
            "figures": record["对应图节"],
        })
    return {"schema": 1, "note": "测试配置：独立功能数据，不导入正式剧情。", "groups": groups, "bases": bases, "operations": operations}


def dump(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="导入目标导航系统配置表")
    parser.add_argument("--check", action="store_true", help="只检查磁盘文件是否与配置表一致")
    args = parser.parse_args()
    try:
        tables = read_tables(SOURCE)
        outputs = {CONFIG_OUT: dump(build_config(tables)), TEST_OUT: dump(build_test_data(tables))}
    except (ImportFailure, KeyError, ValueError) as error:
        print("导入失败：%s" % error, file=sys.stderr)
        return 1
    drift = [path for path, text in outputs.items() if not path.exists() or path.read_text(encoding="utf-8") != text]
    if args.check:
        for path in drift:
            print("与配置表不一致：" + str(path.relative_to(ROOT)))
        print("检查完成：%d 个文件不一致" % len(drift))
        return 1 if drift else 0
    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print("已写入 " + str(path.relative_to(ROOT)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
