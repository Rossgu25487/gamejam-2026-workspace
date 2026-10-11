"""生成可替换的几何PNG占位图；不承载新证明信息，不依赖外部素材。"""
from pathlib import Path
from PIL import Image, ImageDraw

DEST = Path(__file__).resolve().parent.parent / 'game/art/visual/story_samples'


def card(name, accent, mode):
    image = Image.new('RGBA', (320, 480), (28, 37, 47, 255))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((8, 8, 312, 472), 16, fill=accent, outline='#cbbd97', width=3)
    draw.rounded_rectangle((32, 36, 288, 414), 10, fill='#f0e8ce')
    if mode == 'book':
        draw.rectangle((68, 84, 252, 320), fill='#324b53')
        draw.line((94, 84, 94, 320), fill='#d0c092', width=4)
        for y in [130, 164, 198, 232]: draw.line((116, y, 220, y), fill='#d0c092', width=5)
    elif mode == 'label':
        draw.rounded_rectangle((64, 140, 256, 264), 8, outline=accent, width=6)
        draw.text((114, 190), 'A-17', fill=accent, stroke_width=1)
    elif mode == 'portrait':
        draw.ellipse((105, 80, 215, 190), fill=accent)
        draw.rounded_rectangle((66, 206, 254, 340), 35, fill=accent)
    else:
        for y in [118, 162, 206, 250, 294]: draw.line((70, y, 250, y), fill=accent, width=5)
        draw.ellipse((176, 300, 250, 374), outline=accent, width=5)
        if mode == 'wrong': draw.text((104, 74), 'A-71', fill=accent, stroke_width=1)
    image.save(DEST / f'{name}.png')


def background(name, color):
    image = Image.new('RGB', (1280, 800), color)
    draw = ImageDraw.Draw(image)
    for x in range(20, 1280, 80): draw.line((x, 0, x, 800), fill='#1d2a34')
    for y in range(20, 800, 80): draw.line((0, y, 1280, y), fill='#1d2a34')
    image.save(DEST / f'{name}.png')


if __name__ == '__main__':
    DEST.mkdir(parents=True, exist_ok=True)
    background('desk_bg', '#10202a')
    background('archive_bg', '#19252c')
    for name, color, mode in [('ledger', '#47636a', 'book'), ('shelf_label', '#6c7153', 'label'), ('other', '#85584c', 'wrong'), ('lin', '#53657c', 'portrait'), ('receipt', '#536f64', 'paper'), ('inference', '#89784c', 'paper')]:
        card(name, color, mode)
    print('Created 8 geometric PNG placeholders.')
