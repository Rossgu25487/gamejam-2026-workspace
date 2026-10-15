#!/usr/bin/env python3
"""生成声音播放系统的技术测试音频。

1. 对应《声音播放系统配置表》声音资源页 EX_AUDIO_BGM_PULSE：
   自制低音量 220Hz 脉冲 PCM WAV，单声道、48000Hz、16bit、2 秒，只用于验证加载与循环。
   输出确定，可重复生成；起止点均为静音段且 2 秒恰为整数个 220Hz 周期，循环无接缝。
2. 开发运行与声音试玩台使用的三个操作音（点击、确认、文件反馈）：
   自制的短促衰减音，单声道、48000Hz、16bit，只用于在没有正式素材时听到操作反馈；
   正式配置中这三个资源仍为“未绑定”，不会随导出包发出。

只依赖标准库，生成后立即退出。
"""
from __future__ import annotations

import argparse
import math
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 48000
DURATION_SECONDS = 2.0
TONE_HZ = 220.0
PEAK = 0.10  # 约 -20 dBFS，低音量
PULSE_PERIOD = 0.5  # 2 秒内 4 个脉冲
PULSE_ON = 0.30  # 每个脉冲有声段
RAMP = 0.010  # 起止升降沿（秒），避免爆音

FADE_IN = 0.003  # 操作音的起始升沿（秒）
FADE_OUT = 0.006  # 操作音的结尾降沿（秒），保证末采样为 0

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "game" / "tests" / "fixtures" / "design" / "basic" / "test_assets" / "audio" / "ex_bgm_pulse.wav"
DEFAULT_UI_DIR = ROOT / "game" / "tests" / "fixtures" / "audio" / "ui_demo"


def envelope(t: float) -> float:
    """返回时刻 t 的脉冲包络，范围 0 到 1。"""
    phase = t % PULSE_PERIOD
    if phase >= PULSE_ON:
        return 0.0
    if phase < RAMP:
        return 0.5 - 0.5 * math.cos(math.pi * phase / RAMP)
    if phase > PULSE_ON - RAMP:
        return 0.5 - 0.5 * math.cos(math.pi * (PULSE_ON - phase) / RAMP)
    return 1.0


def build_samples() -> list[int]:
    total = int(round(SAMPLE_RATE * DURATION_SECONDS))
    samples: list[int] = []
    for index in range(total):
        t = index / SAMPLE_RATE
        value = PEAK * envelope(t) * math.sin(2.0 * math.pi * TONE_HZ * t)
        samples.append(int(round(value * 32767)))
    return samples


def note(frequency_hz: float, duration: float, decay: float, partials=((1.0, 1.0),)) -> list[float]:
    """生成一个指数衰减的音符，返回 -1 到 1 的采样；partials 为（频率倍数，权重）。"""
    total = int(round(SAMPLE_RATE * duration))
    weight_sum = sum(weight for _, weight in partials)
    values: list[float] = []
    for index in range(total):
        t = index / SAMPLE_RATE
        tone = sum(weight * math.sin(2.0 * math.pi * frequency_hz * ratio * t) for ratio, weight in partials) / weight_sum
        gain = math.exp(-t / decay) * min(1.0, t / FADE_IN) * min(1.0, (duration - t) / FADE_OUT)
        values.append(tone * gain)
    return values


def to_pcm(values: list[float], peak: float) -> list[int]:
    return [int(round(max(-1.0, min(1.0, value * peak)) * 32767)) for value in values]


def build_ui_sounds() -> dict[str, list[int]]:
    """三个操作音：点击是极短的高音，确认是上行两音，文件反馈是柔和的钟声。"""
    return {
        "ui_click": to_pcm(note(1600.0, 0.05, 0.012), 0.30),
        "ui_confirm": to_pcm(note(740.0, 0.09, 0.05) + note(988.0, 0.15, 0.07), 0.28),
        "ui_feedback": to_pcm(note(659.25, 0.45, 0.12, partials=((1.0, 1.0), (1.5, 0.5), (2.0, 0.25))), 0.26),
    }


def write_wav(path: Path, samples: list[int]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(struct.pack("<%dh" % len(samples), *samples))
    return len(samples)


def main() -> int:
    parser = argparse.ArgumentParser(description="生成 EX_AUDIO_BGM_PULSE 与试听操作音")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT, help="脉冲 WAV 输出文件路径")
    parser.add_argument("--ui-dir", type=Path, default=DEFAULT_UI_DIR, help="操作音输出目录")
    args = parser.parse_args()
    frames = write_wav(args.out, build_samples())
    print("已生成 %s（%d 帧，%.1f 秒）" % (args.out, frames, frames / SAMPLE_RATE))
    for name, samples in build_ui_sounds().items():
        target = args.ui_dir / (name + ".wav")
        count = write_wav(target, samples)
        print("已生成 %s（%d 帧，%.3f 秒）" % (target, count, count / SAMPLE_RATE))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
