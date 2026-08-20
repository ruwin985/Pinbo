#!/usr/bin/env python3
from __future__ import annotations

import math
import subprocess
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "pinbo" / "assets"
ICON_PATH = ASSETS / "app-icon.png"

FPS = 30
DURATION = 8.0

FONT_BOLD = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size)


def clamp(value: float, minimum: float = 0.0, maximum: float = 1.0) -> float:
    return max(minimum, min(maximum, value))


def lerp(start: float, end: float, progress: float) -> float:
    return start + (end - start) * progress


def ease_out_cubic(value: float) -> float:
    value = clamp(value)
    return 1 - pow(1 - value, 3)


def ease_in_out(value: float) -> float:
    value = clamp(value)
    return value * value * (3 - 2 * value)


def pulse(t: float, speed: float = 1.0) -> float:
    return 0.5 + 0.5 * math.sin(t * math.tau * speed)


def draw_text(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, fill, size: int, bold: bool = False) -> None:
    draw.text(xy, text, fill=fill, font=font(size, bold=bold))


def text_width(text: str, size: int, bold: bool = False) -> int:
    bbox = ImageDraw.Draw(Image.new("RGB", (1, 1))).textbbox((0, 0), text, font=font(size, bold=bold))
    return bbox[2] - bbox[0]


def centered_text(draw: ImageDraw.ImageDraw, center_x: int, y: int, text: str, fill, size: int, bold: bool = False) -> None:
    draw_text(draw, (center_x - text_width(text, size, bold) // 2, y), text, fill, size, bold)


def rounded_icon(size: int) -> Image.Image:
    icon = Image.open(ICON_PATH).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size, size), radius=max(12, size // 5), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    return out


def make_background(width: int, height: int) -> Image.Image:
    image = Image.new("RGB", (width, height), "#07080c")
    pixels = image.load()
    for y in range(height):
        ratio = y / max(1, height - 1)
        base = int(9 + ratio * 5)
        for x in range(width):
            warm = max(0, 1 - math.hypot((x / width) - 0.18, (y / height) + 0.08) / 0.62)
            hot = max(0, 1 - math.hypot((x / width) - 0.88, (y / height) - 0.16) / 0.48)
            r = min(255, int(base + 58 * warm + 45 * hot))
            g = min(255, int(base + 24 * warm + 6 * hot))
            b = min(255, int(base + 4 * warm + 5 * hot))
            pixels[x, y] = (r, g, b)

    overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    grid = max(42, width // 18)
    for x in range(0, width, grid):
        draw.line((x, 0, x, height), fill=(255, 255, 255, 13), width=1)
    for y in range(0, height, grid):
        draw.line((0, y, width, y), fill=(255, 255, 255, 13), width=1)
    return Image.alpha_composite(image.convert("RGBA"), overlay)


def draw_chip(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, fill=(255, 255, 255, 46)) -> None:
    x, y = xy
    padding_x = 18
    width = text_width(text, 24, True) + padding_x * 2
    draw.rounded_rectangle((x, y, x + width, y + 46), radius=23, fill=fill, outline=(255, 255, 255, 46), width=1)
    draw_text(draw, (x + padding_x, y + 8), text, (255, 255, 255, 216), 24, True)


def draw_progress(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], progress: float) -> None:
    x1, y1, x2, y2 = box
    draw.rounded_rectangle(box, radius=(y2 - y1) // 2, fill=(255, 255, 255, 32))
    draw.rounded_rectangle((x1, y1, int(lerp(x1, x2, clamp(progress))), y2), radius=(y2 - y1) // 2, fill=(255, 112, 32, 230))


def draw_mobile_frame(base: Image.Image, t: float) -> Image.Image:
    image = base.copy()
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = image.size
    icon = rounded_icon(74)
    image.alpha_composite(icon, (46, 46))
    draw_text(draw, (136, 55), "拍呗 Pinbo", (255, 255, 255, 236), 32, True)
    draw_text(draw, (136, 93), "iPhone 创作者录制工作台", (255, 255, 255, 144), 21)

    scenes = [
        (0.0, "前后双摄同框", "场景和人物一次录好"),
        (2.0, "画中画可录后调整", "位置、大小、圆角都可重排"),
        (4.1, "实时字幕自动分段", "录制时生成可编辑字幕"),
        (6.1, "一键导出竖版视频", "适配短视频平台发布"),
    ]
    current = scenes[-1]
    for scene in scenes:
        if t >= scene[0]:
            current = scene
    title_y = 162
    draw_text(draw, (48, title_y), current[1], (255, 255, 255, 245), 58, True)
    draw_text(draw, (50, title_y + 74), current[2], (255, 217, 185, 210), 30)
    draw_chip(draw, (48, title_y + 126), "实时字幕")
    draw_chip(draw, (192, title_y + 126), "可编辑画中画")

    phone_x, phone_y, phone_w, phone_h = 104, 372, 512, 752
    draw.rounded_rectangle((phone_x, phone_y, phone_x + phone_w, phone_y + phone_h), radius=58, fill=(255, 255, 255, 38), outline=(255, 255, 255, 58), width=2)
    screen = (phone_x + 24, phone_y + 58, phone_x + phone_w - 24, phone_y + phone_h - 28)
    draw.rounded_rectangle(screen, radius=34, fill=(12, 15, 24, 255))
    draw.rounded_rectangle((phone_x + phone_w // 2 - 46, phone_y + 25, phone_x + phone_w // 2 + 46, phone_y + 33), radius=4, fill=(255, 255, 255, 70))

    sx1, sy1, sx2, sy2 = screen
    scene_shift = 14 * math.sin(t * 0.8)
    draw.rectangle(screen, fill=(14, 18, 30, 255))
    draw.polygon([(sx1, sy2), (sx2, sy2), (sx2, sy1 + 160 + scene_shift)], fill=(255, 74, 28, 70))
    draw.ellipse((sx1 - 90, sy1 + 80, sx1 + 260, sy1 + 430), fill=(255, 214, 107, 36))
    draw.ellipse((sx2 - 240, sy1 + 230, sx2 + 70, sy1 + 540), fill=(255, 74, 28, 58))
    for offset in range(0, sx2 - sx1, 72):
        x = sx1 + offset + int((t * 18) % 72)
        draw.line((x, sy1, x - 120, sy2), fill=(255, 255, 255, 20), width=2)

    record_alpha = int(150 + 90 * pulse(t, 1.2))
    draw.rounded_rectangle((sx1 + 24, sy1 + 24, sx1 + 168, sy1 + 66), radius=21, fill=(0, 0, 0, 120))
    draw.ellipse((sx1 + 42, sy1 + 39, sx1 + 54, sy1 + 51), fill=(255, 48, 34, record_alpha))
    draw_text(draw, (sx1 + 66, sy1 + 33), f"REC 00:{int(t * 4 + 8):02d}", (255, 255, 255, 210), 19, True)

    pip_progress = ease_in_out((t - 1.6) / 4.0)
    pip_x = int(lerp(sx2 - 172, sx1 + 28, pip_progress))
    pip_y = int(lerp(sy1 + 34, sy1 + 188, 0.5 + 0.5 * math.sin(t * 0.9)))
    pip_size = int(138 + 14 * pulse(t, 0.55))
    draw.rounded_rectangle((pip_x, pip_y, pip_x + pip_size, pip_y + pip_size + 30), radius=28, fill=(255, 255, 255, 44), outline=(255, 255, 255, 72), width=2)
    draw.rounded_rectangle((pip_x + 12, pip_y + 12, pip_x + pip_size - 12, pip_y + pip_size - 4), radius=20, fill=(255, 78, 30, 236))
    draw.ellipse((pip_x + pip_size // 2 - 22, pip_y + 34, pip_x + pip_size // 2 + 22, pip_y + 78), fill=(255, 255, 255, 245))
    draw.pieslice((pip_x + 30, pip_y + 76, pip_x + pip_size - 30, pip_y + 158), 180, 360, fill=(255, 255, 255, 245))

    subtitles = ["今天我们用 30 秒", "讲清楚这个产品亮点", "字幕、画中画、导出一次完成"]
    subtitle_index = min(len(subtitles) - 1, int(max(0, t - 3.2) / 1.35))
    subtitle_text = subtitles[subtitle_index]
    visible_chars = max(1, int(len(subtitle_text) * clamp((t - 3.0 - subtitle_index * 1.35) / 0.9)))
    draw.rounded_rectangle((sx1 + 28, sy2 - 164, sx2 - 28, sy2 - 90), radius=22, fill=(0, 0, 0, 150), outline=(255, 255, 255, 42), width=1)
    centered_text(draw, (sx1 + sx2) // 2, sy2 - 146, subtitle_text[:visible_chars], (255, 255, 255, 245), 25, True)

    draw.rounded_rectangle((sx1 + 28, sy2 - 64, sx2 - 28, sy2 - 28), radius=18, fill=(0, 0, 0, 105))
    draw_progress(draw, (sx1 + 46, sy2 - 50, sx2 - 46, sy2 - 42), t / DURATION)

    draw.rounded_rectangle((78, 1162, width - 78, 1228), radius=33, fill=(255, 83, 30, 235))
    centered_text(draw, width // 2, 1177, "拍摄 · 编辑 · 导出", (255, 255, 255, 245), 28, True)
    return image


def draw_mac_frame(base: Image.Image, t: float) -> Image.Image:
    image = base.copy()
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = image.size
    icon = rounded_icon(68)
    image.alpha_composite(icon, (70, 54))
    draw_text(draw, (154, 63), "拍呗 Pinbo for Mac", (255, 255, 255, 236), 32, True)
    draw_text(draw, (154, 101), "屏幕录制、摄像头画中画、实时字幕", (255, 255, 255, 144), 20)

    scenes = [
        (0.0, "屏幕 + 摄像头同录", "适合软件演示、课程录制和产品讲解"),
        (2.0, "选择窗口 / App / 桌面", "只录需要展示的内容"),
        (4.1, "字幕时间轴可编辑", "边说边生成，录后继续修正"),
        (6.1, "导出完整成片", "统一合成主画面、摄像头、字幕和音乐"),
    ]
    current = scenes[-1]
    for scene in scenes:
        if t >= scene[0]:
            current = scene
    draw_text(draw, (70, 184), current[1], (255, 255, 255, 245), 55, True)
    draw_text(draw, (72, 252), current[2], (255, 217, 185, 210), 25)

    window = (520, 80, 1196, 612)
    wx1, wy1, wx2, wy2 = window
    draw.rounded_rectangle(window, radius=30, fill=(255, 255, 255, 42), outline=(255, 255, 255, 66), width=2)
    draw.rounded_rectangle((wx1 + 14, wy1 + 14, wx2 - 14, wy1 + 62), radius=18, fill=(15, 17, 24, 230))
    for idx, color in enumerate([(255, 95, 87), (255, 189, 46), (39, 201, 63)]):
        cx = wx1 + 42 + idx * 28
        draw.ellipse((cx - 7, wy1 + 34 - 7, cx + 7, wy1 + 34 + 7), fill=color + (230,))
    draw_text(draw, (wx1 + 142, wy1 + 24), "Pinbo Recording Workspace", (255, 255, 255, 150), 18, True)

    content = (wx1 + 24, wy1 + 82, wx2 - 24, wy2 - 96)
    cx1, cy1, cx2, cy2 = content
    draw.rounded_rectangle(content, radius=22, fill=(9, 12, 20, 255))
    draw.rectangle((cx1, cy1, cx2, cy2), fill=(11, 14, 23, 255))
    draw.ellipse((cx1 + 70, cy1 + 64, cx1 + 360, cy1 + 354), fill=(255, 214, 107, 34))
    draw.ellipse((cx2 - 340, cy1 + 48, cx2 - 16, cy1 + 372), fill=(255, 74, 28, 48))
    grid = 58
    for x in range(cx1, cx2, grid):
        draw.line((x + int((t * 16) % grid), cy1, x + int((t * 16) % grid), cy2), fill=(255, 255, 255, 18), width=1)
    for y in range(cy1, cy2, grid):
        draw.line((cx1, y, cx2, y), fill=(255, 255, 255, 14), width=1)

    picker_alpha = int(120 * clamp(1 - abs(t - 2.8) / 1.8))
    if picker_alpha > 2:
        chips = ["全屏", "窗口", "App"]
        for idx, label in enumerate(chips):
            x = 82 + idx * 132
            y = 330
            draw.rounded_rectangle((x, y, x + 110, y + 54), radius=27, fill=(255, 255, 255, picker_alpha), outline=(255, 255, 255, picker_alpha // 2), width=1)
            draw_text(draw, (x + 27, y + 13), label, (255, 255, 255, 210), 23, True)

    pip_x = int(lerp(cx2 - 192, cx2 - 248, pulse(t, 0.22)))
    pip_y = int(lerp(cy1 + 28, cy1 + 84, pulse(t + 1.1, 0.2)))
    draw.rounded_rectangle((pip_x, pip_y, pip_x + 176, pip_y + 134), radius=26, fill=(255, 255, 255, 46), outline=(255, 255, 255, 74), width=2)
    draw.rounded_rectangle((pip_x + 12, pip_y + 12, pip_x + 164, pip_y + 122), radius=18, fill=(255, 78, 30, 235))
    draw.ellipse((pip_x + 72, pip_y + 30, pip_x + 104, pip_y + 62), fill=(255, 255, 255, 245))
    draw.pieslice((pip_x + 48, pip_y + 62, pip_x + 128, pip_y + 126), 180, 360, fill=(255, 255, 255, 245))

    subtitle = "录屏、出镜和字幕同步完成"
    visible = max(1, int(len(subtitle) * clamp((t - 3.7) / 1.5)))
    draw.rounded_rectangle((cx1 + 72, cy2 - 86, cx2 - 72, cy2 - 30), radius=20, fill=(0, 0, 0, 150), outline=(255, 255, 255, 42), width=1)
    centered_text(draw, (cx1 + cx2) // 2, cy2 - 74, subtitle[:visible], (255, 255, 255, 245), 26, True)

    timeline = (wx1 + 24, wy2 - 72, wx2 - 24, wy2 - 28)
    draw.rounded_rectangle(timeline, radius=22, fill=(0, 0, 0, 110))
    draw_progress(draw, (timeline[0] + 24, timeline[1] + 18, timeline[2] - 24, timeline[1] + 27), t / DURATION)
    draw_text(draw, (timeline[0] + 24, timeline[1] - 26), "Timeline metadata", (255, 255, 255, 120), 18, True)

    draw.rounded_rectangle((70, 454, 410, 516), radius=31, fill=(255, 83, 30, 236))
    centered_text(draw, 240, 470, "下载 Mac 版 DMG", (255, 255, 255, 245), 25, True)
    draw.rounded_rectangle((70, 540, 360, 586), radius=23, fill=(255, 255, 255, 38), outline=(255, 255, 255, 48), width=1)
    centered_text(draw, 215, 551, "Universal · macOS 12.3+", (255, 255, 255, 190), 18, True)
    return image


def encode_video(width: int, height: int, output: Path, renderer) -> None:
    command = [
        "ffmpeg", "-y",
        "-f", "rawvideo",
        "-pix_fmt", "rgba",
        "-s", f"{width}x{height}",
        "-r", str(FPS),
        "-i", "-",
        "-an",
        "-vf", "format=yuv420p",
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "23",
        "-movflags", "+faststart",
        str(output),
    ]
    base = make_background(width, height)
    with subprocess.Popen(command, stdin=subprocess.PIPE) as process:
        assert process.stdin is not None
        for frame in range(int(DURATION * FPS)):
            t = frame / FPS
            image = Image.alpha_composite(base, renderer(base, t)).convert("RGBA")
            process.stdin.write(image.tobytes())
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError(f"ffmpeg failed for {output}")


def save_poster(width: int, height: int, output: Path, renderer, t: float) -> None:
    base = make_background(width, height)
    image = Image.alpha_composite(base, renderer(base, t)).convert("RGB")
    image.save(output, quality=92)


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    outputs: Iterable[tuple[int, int, str, object, float]] = [
        (720, 1280, "promo-ios", draw_mobile_frame, 4.4),
        (1280, 720, "promo-mac", draw_mac_frame, 4.4),
    ]
    for width, height, name, renderer, poster_time in outputs:
        mp4 = ASSETS / f"{name}.mp4"
        poster = ASSETS / f"{name}-poster.png"
        print(f"Rendering {mp4.name}...")
        encode_video(width, height, mp4, renderer)
        save_poster(width, height, poster, renderer, poster_time)
        print(f"Wrote {mp4} and {poster}")


if __name__ == "__main__":
    main()
