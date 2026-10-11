#!/usr/bin/env python3
"""获取声音系统试听用的古典乐／颂歌片段（仅作测试音频，不进入正式导出）。

- 曲目取自 Wikimedia Commons，只接受授权标注为公有领域、CC0 或 CC BY 的文件；
- 每首截取开头一段，加淡入淡出，统一响度，转成 OGG Vorbis，放在 game/tests/fixtures/music/；
- 来源页、作者、授权、校验值写入 manifest.json，试听台直接读取它显示署名；
- 授权以 Commons 页面标注为准，正式发布前请再核对。

依赖（仅重新生成素材时需要，游戏本身不依赖）：pip install soundfile numpy
完成后直接退出。--dry-run 只核对授权不下载。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "game" / "tests" / "fixtures" / "music"
CACHE_DIR = ROOT / ".local" / "music_cache"
API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "Gamejam2026-TestMusic/1.0 (game jam local test assets)"

# 十首试听曲目：id、Commons 文件名、作品信息、传统分类、截取起点与长度（秒）
TRACKS = [
    {"id": "bach_toccata", "file": "Toccata et Fugue BWV565.ogg", "composer": "J. S. Bach",
     "work": "d小调托卡塔与赋格 BWV 565（管风琴）", "tradition": "德国古典", "start": 0.0, "length": 80.0},
    {"id": "mozart_k525", "file": "Mozart K525 Serenade in G Major 1 - Allegro.ogg", "composer": "W. A. Mozart",
     "work": "小夜曲 K.525 第一乐章", "tradition": "德奥古典", "start": 0.0, "length": 75.0},
    {"id": "wagner_valkyries", "file": "Richard Wagner - Ride of the Valkyries.ogg", "composer": "Richard Wagner",
     "work": "女武神的骑行（爱迪生唱片）", "tradition": "德国古典", "start": 0.0, "length": 75.0},
    {"id": "beethoven_ode_to_joy", "file": "Ode to Joy.ogg", "composer": "L. van Beethoven",
     "work": "第九交响曲《欢乐颂》主题", "tradition": "德国古典", "start": 0.0, "length": 38.0},
    {"id": "joyful_joyful_usaf", "file": "Ode to Joy - Concert Band - United States Air Force Band of the Rockies.mp3",
     "composer": "Beethoven / H. van Dyke", "work": "Joyful, Joyful We Adore Thee（欢乐颂圣诗版）",
     "tradition": "基督教颂歌", "start": 0.0, "length": 80.0},
    {"id": "ussr_anthem_1968", "file": "Hymn of ussr instrumental.ogg", "composer": "A. Alexandrov",
     "work": "苏联国歌（1968 年器乐版）", "tradition": "苏联", "start": 0.0, "length": 70.0},
    {"id": "khachaturian_armssr", "file": "Anthem of the Armenian Soviet Socialist Republic (Instrumental).ogg",
     "composer": "A. Khachaturian", "work": "亚美尼亚苏维埃共和国国歌（器乐）", "tradition": "苏联古典",
     "start": 0.0, "length": 75.0},
    {"id": "dies_irae_chant", "file": "Dies.irae.ogg", "composer": "格里高利圣咏",
     "work": "震怒之日 Dies irae（安魂弥撒续抒咏）", "tradition": "基督教圣咏", "start": 0.0, "length": 90.0},
    {"id": "mozart_requiem_dies_irae",
     "file": "W. A. Mozart - Requiem, K. 626 (Bruno Walter, Wiener Philharmoniker, Wiener Staatsopernchor, 1956) - 03. Dies irae.ogg",
     "composer": "W. A. Mozart", "work": "安魂曲 K.626：震怒之日", "tradition": "德奥古典／基督教",
     "start": 0.0, "length": 80.0},
    {"id": "ein_feste_burg",
     "file": "\"Ein feste Burg\" performed by the United States Army Band in December 2018.oga",
     "composer": "Martin Luther", "work": "Ein feste Burg ist unser Gott（路德圣咏）", "tradition": "基督教颂歌",
     "start": 0.0, "length": 75.0},
]

TARGET_RMS = 0.10  # 约 -20 dBFS，各曲响度接近
PEAK_LIMIT = 0.90
FADE_IN = 0.3
FADE_OUT = 1.5


def license_allowed(name: str) -> bool:
    """只接受公有领域、CC0、无附加限制的 CC BY。"""
    lowered = name.strip().lower()
    return lowered.startswith("public domain") or lowered.startswith("pd") or lowered == "cc0" or bool(
        re.fullmatch(r"cc by \d\.\d", lowered)
    )


def strip_html(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", text or "")).strip()


def api_call(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(5):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as error:  # 网络或限流：退避后重试
            print("  接口重试 %d：%r" % (attempt + 1, error), file=sys.stderr)
            time.sleep(6 * (attempt + 1))
    raise SystemExit("无法访问 Wikimedia Commons 接口")


def fetch_metadata() -> dict:
    titles = ["File:" + track["file"] for track in TRACKS]
    data = api_call({"action": "query", "titles": "|".join(titles), "prop": "imageinfo",
                     "iiprop": "url|size|mime|extmetadata", "format": "json"})
    result = {}
    for page in data["query"]["pages"].values():
        info = (page.get("imageinfo") or [None])[0]
        if info is None:
            continue
        meta = info.get("extmetadata", {})
        pick = lambda key: strip_html(meta.get(key, {}).get("value", ""))
        result[page["title"][len("File:"):]] = {
            "license": pick("LicenseShortName"),
            "license_url": meta.get("LicenseUrl", {}).get("value", ""),
            "artist": pick("Artist"),
            "credit": pick("Credit"),
            "url": info["url"].split("?")[0],
            "page_url": "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(page["title"][len("File:"):].replace(" ", "_")),
            "bytes": info.get("size", 0),
        }
    # Commons 会规范化标题（例如首字母或空格），按规范化后的名字回查
    return result


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size > 0:
        return
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as handle:
                handle.write(response.read())
            return
        except Exception as error:
            print("  下载重试 %d：%r" % (attempt + 1, error), file=sys.stderr)
            time.sleep(6 * (attempt + 1))
    raise SystemExit("下载失败：" + url)


def process(source: Path, destination: Path, start: float, length: float) -> float:
    import numpy as np
    import soundfile as sf

    data, rate = sf.read(str(source), dtype="float32", always_2d=True)
    begin = int(start * rate)
    end = min(len(data), begin + int(length * rate))
    clip = data[begin:end].copy()
    if len(clip) == 0:
        raise ValueError("截取范围为空：" + source.name)
    fade_in = min(int(FADE_IN * rate), len(clip) // 4)
    fade_out = min(int(FADE_OUT * rate), len(clip) // 4)
    if fade_in:
        clip[:fade_in] *= np.linspace(0.0, 1.0, fade_in, dtype="float32")[:, None]
    if fade_out:
        clip[-fade_out:] *= np.linspace(1.0, 0.0, fade_out, dtype="float32")[:, None]
    rms = float(np.sqrt(np.mean(np.square(clip))))
    peak = float(np.max(np.abs(clip)))
    gain = min(TARGET_RMS / max(rms, 1e-9), PEAK_LIMIT / max(peak, 1e-9))
    destination.parent.mkdir(parents=True, exist_ok=True)
    scaled = clip * gain
    # libsndfile 的 Vorbis 编码器一次写入大数组会在 Windows 上栈溢出，必须分小块写入
    with sf.SoundFile(str(destination), "w", samplerate=rate, channels=scaled.shape[1],
                      format="OGG", subtype="VORBIS") as handle:
        for index in range(0, len(scaled), 4096):
            handle.write(scaled[index:index + 4096])
    return len(clip) / rate


def main() -> int:
    parser = argparse.ArgumentParser(description="获取并处理试听古典乐")
    parser.add_argument("--dry-run", action="store_true", help="只核对授权，不下载不处理")
    args = parser.parse_args()
    metadata = fetch_metadata()
    manifest = []
    for track in TRACKS:
        key = track["file"].replace("_", " ")
        info = metadata.get(key) or metadata.get(track["file"])
        if info is None:
            print("  找不到：%s" % track["file"], file=sys.stderr)
            continue
        allowed = license_allowed(info["license"])
        print("%-26s %-18s %s" % (track["id"], info["license"], "通过" if allowed else "拒绝"))
        if not allowed or args.dry_run:
            continue
        cache = CACHE_DIR / (track["id"] + Path(track["file"]).suffix)
        download(info["url"], cache)
        destination = OUT_DIR / (track["id"] + ".ogg")
        seconds = process(cache, destination, track["start"], track["length"])
        manifest.append({
            "id": track["id"], "file": destination.name, "composer": track["composer"], "work": track["work"],
            "tradition": track["tradition"], "performer": info["artist"], "license": info["license"],
            "license_url": info["license_url"], "source_url": info["url"], "page_url": info["page_url"],
            "credit": info["credit"], "clip_start": track["start"], "clip_length": round(seconds, 2),
            "bytes": destination.stat().st_size, "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        })
        time.sleep(1.5)
    if args.dry_run:
        return 0
    manifest_path = OUT_DIR / "manifest.json"
    manifest_path.write_text(json.dumps({"schema": 1, "note": "试听用古典乐片段，仅作测试音频；授权以 Commons 页面标注为准。", "tracks": manifest},
                                        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    total = sum(item["bytes"] for item in manifest)
    print("已生成 %d 首，合计 %.1f MB -> %s" % (len(manifest), total / 1048576.0, OUT_DIR))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
