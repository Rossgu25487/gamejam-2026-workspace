#!/usr/bin/env python3
"""扫描 game/music 下的音效素材（忽略 .zip 与 .url），生成备用音效库目录 game/data/audio/sfx_library.json。

特点：
- 自动忽略 .zip 压缩包、.url 快捷方式、.txt 授权说明和 .import 导入侧文件；
- 提取真实音频时长、采样率、声道数、编码格式与字节大小；
- 为每条音效分配稳定调用 ID（SFX_*）、中文名称、来源包、分类、推荐总线与简写别名；
- 只依赖标准库，完成后直接退出；--check 仅校验磁盘 JSON 是否与当前素材一致。
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MUSIC_DIR = ROOT / "game" / "music"
OUTPUT_PATH = ROOT / "game" / "data" / "audio" / "sfx_library.json"

PACK_META = {
    "available_audios": {
        "id": "available_audios",
        "label": "专项候选音效 (Available)",
        "license": "项目专项候选音效 (available_audios)",
        "order": 0,
    },
    "kenney_rpg-audio": {
        "id": "kenney_rpg",
        "label": "书卷门锁与道具 (Kenney RPG)",
        "license": "CC0 1.0 Public Domain (Kenney.nl)",
        "order": 1,
    },
    "kenney_casino-audio": {
        "id": "kenney_casino",
        "label": "卡牌筹码与骰子 (Kenney Casino)",
        "license": "CC0 1.0 Public Domain (Kenney.nl)",
        "order": 2,
    },
    "kenney_impact-sounds": {
        "id": "kenney_impact",
        "label": "脚步与材质撞击 (Kenney Impact)",
        "license": "CC0 1.0 Public Domain (Kenney.nl)",
        "order": 3,
    },
}

CATEGORY_META = {
    "game_cue": {"label": "剧情与卡牌提示", "order": 0},
    "book": {"label": "书卷与翻页", "order": 1},
    "card": {"label": "卡牌操作", "order": 2},
    "door": {"label": "门锁与木门", "order": 3},
    "coin_metal": {"label": "金属机关与钱币", "order": 4},
    "cloth_leather": {"label": "衣物与皮革", "order": 5},
    "chip": {"label": "筹码操作", "order": 6},
    "dice": {"label": "骰子操作", "order": 7},
    "footstep": {"label": "脚步声", "order": 8},
    "impact_bell": {"label": "钟铃与通用轻击", "order": 9},
    "impact_wood": {"label": "木质撞击", "order": 10},
    "impact_glass": {"label": "玻璃撞击", "order": 11},
    "impact_metal": {"label": "金属与铁皮撞击", "order": 12},
    "impact_stone": {"label": "石矿与板材撞击", "order": 13},
    "impact_punch_soft": {"label": "拳击与软物闷响", "order": 14},
    "blade": {"label": "刀刃与劈砍", "order": 15},
    "preview": {"label": "资源包预览串烧", "order": 16},
}

SPECIAL_AVAILABLE = {
    "对白显示音效": {
        "id": "SFX_AVAIL_DIALOGUE_SHOW",
        "name": "对白显示音效",
        "category": "game_cue",
        "bus": "ui",
        "aliases": ["SFX_DIALOGUE_SHOW", "对白显示音效", "对白显示音效.wav"],
        "usage": "对话文本逐字或整段显示时的提示音",
    },
    "时间／地点显示音效": {
        "id": "SFX_AVAIL_TIME_PLACE_SHOW",
        "name": "时间／地点显示音效",
        "category": "game_cue",
        "bus": "ui",
        "aliases": ["SFX_TIME_PLACE_SHOW", "时间／地点显示音效", "时间/地点显示音效", "时间／地点显示音效.wav"],
        "usage": "场景时间或地点标题浮现时的提示音",
    },
    "证物／证言／推论获取转卡牌音效": {
        "id": "SFX_AVAIL_EVIDENCE_TO_CARD",
        "name": "证物／证言／推论获取转卡牌音效",
        "category": "game_cue",
        "bus": "result",
        "aliases": [
            "SFX_EVIDENCE_TO_CARD",
            "证物／证言／推论获取转卡牌音效",
            "证物/证言/推论获取转卡牌音效",
            "证物／证言／推论获取转卡牌音效.wav",
        ],
        "usage": "获得证物、证言或推论并转化为手牌时的结果音",
    },
}


def inspect_ogg(path: Path) -> dict:
    data = path.read_bytes()
    if data[:4] != b"OggS":
        raise ValueError("Invalid Ogg file: %s" % path)
    marker = data.find(b"\x01vorbis")
    if marker < 0:
        return {"format": "ogg", "channels": 2, "sample_rate": 44100, "duration_sec": 0.0}
    channels = data[marker + 11]
    rate = struct.unpack("<I", data[marker + 12 : marker + 16])[0]
    last = data.rfind(b"OggS")
    granule = struct.unpack("<q", data[last + 6 : last + 14])[0]
    duration = round(granule / rate, 3) if rate else 0.0
    return {"format": "ogg", "channels": int(channels), "sample_rate": int(rate), "duration_sec": duration}


def inspect_wav(path: Path) -> dict:
    with wave.open(str(path), "rb") as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        channels = handle.getnchannels()
    duration = round(frames / rate, 3) if rate else 0.0
    return {"format": "wav", "channels": int(channels), "sample_rate": int(rate), "duration_sec": duration}


def snake_upper(stem: str) -> str:
    step = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", stem)
    step = re.sub(r"[^A-Za-z0-9]+", "_", step).strip("_")
    return step.upper()


def classify_casino(stem: str) -> tuple[str, str, str, str]:
    if stem == "Preview":
        return "SFX_CASINO_PREVIEW", "卡牌与筹码包预览串烧", "preview", "result"
    token = snake_upper(stem)
    sfx_id = "SFX_CASINO_" + token
    parts = stem.split("-")
    num = parts[-1] if parts[-1].isdigit() else ""
    if stem.startswith("card-fan-"):
        return sfx_id, "卡牌扇形展开 " + num, "card", "ui"
    if stem.startswith("card-place-"):
        return sfx_id, "放置卡牌 " + num, "card", "ui"
    if stem.startswith("card-shove-"):
        return sfx_id, "推动卡牌 " + num, "card", "ui"
    if stem == "card-shuffle":
        return sfx_id, "洗牌音效", "card", "ui"
    if stem.startswith("card-slide-"):
        return sfx_id, "滑动卡牌 " + num, "card", "ui"
    if stem.startswith("cards-pack-open-"):
        return sfx_id, "拆开卡包 " + num, "card", "result"
    if stem.startswith("cards-pack-take-out-"):
        return sfx_id, "取出整叠卡牌 " + num, "card", "ui"
    if stem.startswith("chip-lay-"):
        return sfx_id, "放下筹码 " + num, "chip", "ui"
    if stem.startswith("chips-collide-"):
        return sfx_id, "筹码碰撞 " + num, "chip", "result"
    if stem.startswith("chips-handle-"):
        return sfx_id, "拨弄筹码 " + num, "chip", "result"
    if stem.startswith("chips-stack-"):
        return sfx_id, "堆叠筹码 " + num, "chip", "ui"
    if stem.startswith("dice-grab-"):
        return sfx_id, "抓起骰子 " + num, "dice", "result"
    if stem.startswith("dice-shake-"):
        return sfx_id, "摇晃骰子 " + num, "dice", "result"
    if stem.startswith("dice-throw-"):
        return sfx_id, "投掷多颗骰子 " + num, "dice", "result"
    if stem.startswith("die-throw-"):
        return sfx_id, "投掷单颗骰子 " + num, "dice", "result"
    return sfx_id, "桌面音效 " + stem, "card", "result"


def classify_impact(stem: str) -> tuple[str, str, str, str]:
    token = snake_upper(stem)
    if token.startswith("IMPACT_"):
        sfx_id = "SFX_" + token
    else:
        sfx_id = "SFX_IMPACT_" + token
    parts = stem.split("_")
    num = parts[-1] if parts[-1].isdigit() else ""
    strength_map = {"heavy": "重击", "medium": "中击", "light": "轻击"}
    strength = strength_map.get(parts[1], "") if len(parts) >= 3 else ""
    if stem.startswith("footstep_carpet_"):
        return sfx_id, "地毯脚步 " + num, "footstep", "result"
    if stem.startswith("footstep_concrete_"):
        return sfx_id, "水泥地脚步 " + num, "footstep", "result"
    if stem.startswith("footstep_grass_"):
        return sfx_id, "草地脚步 " + num, "footstep", "result"
    if stem.startswith("footstep_snow_"):
        return sfx_id, "雪地脚步 " + num, "footstep", "result"
    if stem.startswith("footstep_wood_"):
        return sfx_id, "木地板脚步 " + num, "footstep", "result"
    if stem.startswith("impactBell_"):
        return sfx_id, "重钟敲击 " + num, "impact_bell", "result"
    if stem.startswith("impactGeneric_"):
        return sfx_id, "通用轻敲 " + num, "impact_bell", "ui"
    if stem.startswith("impactGlass_"):
        return sfx_id, "玻璃%s %s" % (strength, num), "impact_glass", "result"
    if stem.startswith("impactMetal_"):
        return sfx_id, "金属%s %s" % (strength, num), "impact_metal", "result"
    if stem.startswith("impactTin_"):
        return sfx_id, "铁皮撞击 " + num, "impact_metal", "result"
    if stem.startswith("impactMining_"):
        return sfx_id, "石矿敲击 " + num, "impact_stone", "result"
    if stem.startswith("impactPlate_"):
        return sfx_id, "板材%s %s" % (strength, num), "impact_stone", "result"
    if stem.startswith("impactPlank_"):
        return sfx_id, "木板撞击 " + num, "impact_wood", "result"
    if stem.startswith("impactWood_"):
        return sfx_id, "木质%s %s" % (strength, num), "impact_wood", "result"
    if stem.startswith("impactPunch_"):
        return sfx_id, "拳击%s %s" % (strength, num), "impact_punch_soft", "result"
    if stem.startswith("impactSoft_"):
        return sfx_id, "软物%s %s" % (strength, num), "impact_punch_soft", "result"
    return sfx_id, "撞击音效 " + stem, "impact_wood", "result"


def classify_rpg(stem: str) -> tuple[str, str, str, str]:
    if stem == "Preview":
        return "SFX_RPG_PREVIEW", "书卷门锁与道具包预览串烧", "preview", "result"
    sfx_id = "SFX_RPG_" + snake_upper(stem)
    digits = re.findall(r"\d+$", stem)
    num = (" " + digits[0]) if digits else ""
    if stem == "bookClose":
        return sfx_id, "合上书卷", "book", "ui"
    if stem == "bookOpen":
        return sfx_id, "翻开书卷", "book", "ui"
    if stem.startswith("bookFlip"):
        return sfx_id, "翻阅书页" + num, "book", "ui"
    if stem.startswith("bookPlace"):
        return sfx_id, "放下书卷" + num, "book", "ui"
    if stem.startswith("creak"):
        return sfx_id, "木门与地板吱呀" + num, "door", "result"
    if stem.startswith("doorClose"):
        return sfx_id, "关闭木门" + num, "door", "result"
    if stem.startswith("doorOpen"):
        return sfx_id, "推开木门" + num, "door", "result"
    if stem.startswith("beltHandle"):
        return sfx_id, "皮带金属扣" + num, "cloth_leather", "result"
    if stem.startswith("clothBelt"):
        return sfx_id, "整理腰带" + num, "cloth_leather", "result"
    if stem.startswith("cloth"):
        return sfx_id, "衣物摩擦" + num, "cloth_leather", "result"
    if stem == "dropLeather":
        return sfx_id, "皮革物品放下", "cloth_leather", "result"
    if stem.startswith("handleSmallLeather"):
        return sfx_id, "拿取小皮具" + num, "cloth_leather", "result"
    if stem.startswith("handleCoins"):
        return sfx_id, "拨弄硬币" + num, "coin_metal", "result"
    if stem == "metalClick":
        return sfx_id, "金属咔哒（机关／按钮）", "coin_metal", "ui"
    if stem == "metalLatch":
        return sfx_id, "金属锁扣合拢", "coin_metal", "ui"
    if stem.startswith("metalPot"):
        return sfx_id, "金属容器碰撞" + num, "coin_metal", "result"
    if stem == "chop":
        return sfx_id, "利器劈砍", "blade", "result"
    if stem.startswith("drawKnife"):
        return sfx_id, "拔出短刀" + num, "blade", "result"
    if stem.startswith("knifeSlice"):
        return sfx_id, "刀刃挥砍" + num, "blade", "result"
    if stem.startswith("footstep"):
        return sfx_id, "室内脚步" + num, "footstep", "result"
    return sfx_id, "道具音效 " + stem, "coin_metal", "result"


def build_library() -> dict:
    if not MUSIC_DIR.is_dir():
        raise RuntimeError("未找到音效目录：%s" % MUSIC_DIR)

    entries: list[dict] = []
    seen_ids: set[str] = set()
    stem_counts: dict[str, int] = {}

    audio_files = sorted(
        path
        for path in MUSIC_DIR.rglob("*")
        if path.is_file() and path.suffix.lower() in (".ogg", ".wav")
    )
    for path in audio_files:
        stem_counts[path.stem] = stem_counts.get(path.stem, 0) + 1

    for path in audio_files:
        rel_to_music = path.relative_to(MUSIC_DIR)
        top_folder = rel_to_music.parts[0]
        pack_info = PACK_META.get(
            top_folder,
            {"id": top_folder, "label": top_folder, "license": "Unknown", "order": 99},
        )
        stem = path.stem
        info = inspect_ogg(path) if path.suffix.lower() == ".ogg" else inspect_wav(path)
        res_path = "res://music/" + rel_to_music.as_posix()

        if top_folder == "available_audios" and stem in SPECIAL_AVAILABLE:
            spec = SPECIAL_AVAILABLE[stem]
            sfx_id = spec["id"]
            name = spec["name"]
            category = spec["category"]
            bus = spec["bus"]
            aliases = list(spec["aliases"])
            usage = spec["usage"]
        elif top_folder == "kenney_casino-audio":
            sfx_id, name, category, bus = classify_casino(stem)
            aliases = [] if stem_counts[stem] > 1 else [stem, path.name]
            usage = CATEGORY_META[category]["label"]
        elif top_folder == "kenney_impact-sounds":
            sfx_id, name, category, bus = classify_impact(stem)
            aliases = [] if stem_counts[stem] > 1 else [stem, path.name]
            usage = CATEGORY_META[category]["label"]
        elif top_folder == "kenney_rpg-audio":
            sfx_id, name, category, bus = classify_rpg(stem)
            aliases = [] if stem_counts[stem] > 1 else [stem, path.name]
            usage = CATEGORY_META[category]["label"]
        else:
            sfx_id = "SFX_" + snake_upper(stem)
            name = stem
            category = "game_cue"
            bus = "result"
            aliases = [stem, path.name]
            usage = "备用音效"

        if sfx_id in seen_ids:
            raise RuntimeError("重复的备用音效 ID：%s" % sfx_id)
        seen_ids.add(sfx_id)

        cat_info = CATEGORY_META[category]
        entries.append(
            {
                "id": sfx_id,
                "name": name,
                "stem": stem,
                "pack": pack_info["id"],
                "pack_label": pack_info["label"],
                "category": category,
                "category_label": cat_info["label"],
                "bus": bus,
                "path": res_path,
                "format": info["format"],
                "duration_sec": info["duration_sec"],
                "sample_rate": info["sample_rate"],
                "channels": info["channels"],
                "size_bytes": path.stat().st_size,
                "license": pack_info["license"],
                "usage": usage,
                "aliases": aliases,
                "_sort": (pack_info["order"], cat_info["order"], sfx_id),
            }
        )

    entries.sort(key=lambda item: item["_sort"])
    for item in entries:
        item.pop("_sort", None)

    packs = []
    for folder, meta in sorted(PACK_META.items(), key=lambda pair: pair[1]["order"]):
        count = sum(1 for item in entries if item["pack"] == meta["id"])
        if count > 0:
            packs.append(
                {
                    "id": meta["id"],
                    "label": meta["label"],
                    "license": meta["license"],
                    "count": count,
                }
            )

    categories = []
    for cat_id, meta in sorted(CATEGORY_META.items(), key=lambda pair: pair[1]["order"]):
        count = sum(1 for item in entries if item["category"] == cat_id)
        if count > 0:
            categories.append(
                {
                    "id": cat_id,
                    "label": meta["label"],
                    "count": count,
                }
            )

    return {
        "schema": 1,
        "total_count": len(entries),
        "packs": packs,
        "categories": categories,
        "entries": entries,
    }


def render(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成备用音效库目录 sfx_library.json")
    parser.add_argument("--check", action="store_true", help="仅检查磁盘 JSON 是否与当前素材一致")
    args = parser.parse_args()
    data = build_library()
    text = render(data)
    if args.check:
        if not OUTPUT_PATH.is_file() or OUTPUT_PATH.read_text(encoding="utf-8") != text:
            print("备用音效库配置与磁盘不一致：%s" % OUTPUT_PATH, file=sys.stderr)
            return 1
        print("备用音效库配置一致，共 %d 条。" % data["total_count"])
        return 0
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(text, encoding="utf-8", newline="\n")
    print(
        "已生成备用音效库：%d 条音效（%d 个来源包、%d 个分类）-> %s"
        % (
            data["total_count"],
            len(data["packs"]),
            len(data["categories"]),
            OUTPUT_PATH.relative_to(ROOT),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
