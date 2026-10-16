"""将策划测试包原字节复制到运行目录；不修改策划原表或玩家进度。"""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import base64
import io
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT = REPO / 'game/代码开发需求/测试用资源'
TARGET = REPO / 'game/data/system_test/package'

def flatten_embedded_svg(original: Path, destination: Path) -> None:
    """本包SVG是嵌入位图的裁剪载体；Godot不支持其中image，按原几何生成PNG。"""
    from PIL import Image
    svg = ET.parse(original).getroot()
    ns = {'s': 'http://www.w3.org/2000/svg'}
    nested = svg.find('s:svg', ns)
    embedded = svg.find('.//s:image', ns)
    if nested is None or embedded is None or not embedded.get('href', '').startswith('data:image/png;base64,'):
        raise ValueError(f'不支持的测试SVG结构，需提供PNG：{original.name}')
    source = Image.open(io.BytesIO(base64.b64decode(embedded.get('href').split(',', 1)[1]))).convert('RGBA')
    x, y, w, h = map(float, nested.get('viewBox').split())
    crop = source.crop((round(x), round(y), round(x+w), round(y+h)))
    width, height = round(float(nested.get('width'))), round(float(nested.get('height')))
    factor = min(width/crop.width, height/crop.height)
    crop = crop.resize((round(crop.width*factor), round(crop.height*factor)), Image.Resampling.LANCZOS)
    result = Image.new('RGBA', (round(float(svg.get('width'))), round(float(svg.get('height')))))
    ox = round(float(nested.get('x', 0))) + (width-crop.width)//2
    oy = round(float(nested.get('y', 0))) + (height-crop.height if 'YMax' in nested.get('preserveAspectRatio', '') else (height-crop.height)//2)
    result.alpha_composite(crop, (ox, oy))
    destination.parent.mkdir(parents=True, exist_ok=True)
    result.save(destination)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT)
    args = parser.parse_args()
    source = args.source.resolve()
    profile = json.loads((REPO / 'game/data/system_test/profile.json').read_text(encoding='utf-8-sig'))
    files = [source / '配置表' / name for name in profile['workbooks'].values() if not name.startswith('res://')]
    for directory in ['assets', 'audio']:
        files.extend(p for p in (source / directory).rglob('*') if p.is_file() and p.suffix != '.import' and not p.name.startswith('~$'))
    files.extend(source / name for name in ['声音资源映射.md', '测试资源清单.md', '十一系统贯通测试用例.md'])
    missing = [str(p) for p in files if not p.is_file()]
    if missing:
        raise SystemExit('缺少测试包文件：\n' + '\n'.join(missing))
    records = []
    generated = []
    for original in sorted(files):
        relative = original.relative_to(source)
        destination = TARGET / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(original.read_bytes()).hexdigest()
        if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            shutil.copyfile(original, destination)
        records.append({'path': relative.as_posix(), 'sha256': digest})
        if original.suffix == '.svg':
            output = TARGET.parent / 'generated' / relative.with_suffix('.png')
            flatten_embedded_svg(original, output)
            generated.append({'source': relative.as_posix(), 'path': output.relative_to(TARGET.parent).as_posix(), 'sha256': hashlib.sha256(output.read_bytes()).hexdigest()})
    (TARGET.parent / 'source_manifest.json').write_text(json.dumps({'schema': 1, 'source': 'game/代码开发需求/测试用资源', 'files': records, 'generated': generated}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'已准备 {len(records)} 个原字节文件；运行目录 {TARGET}')

if __name__ == '__main__':
    main()
