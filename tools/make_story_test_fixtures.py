"""只在 .local 生成故事配置回归夹具，不修改玩家填写的工作簿。"""
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'game/data/story/outputs/story-config-20261011/故事配置表.xlsx'
DEST = ROOT / '.local/story-workbook/fixtures'
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
Q = lambda name: f'{{{NS}}}{name}'
ET.register_namespace('x', NS)


def set_cell(sheet, address, value, formula=None):
    number = ''.join(c for c in address if c.isdigit())
    data = sheet.find(Q('sheetData'))
    row = next((r for r in data if r.get('r') == number), None)
    if row is None:
        row = ET.SubElement(data, Q('row'), {'r': number})
    cell = next((c for c in row if c.get('r') == address), None)
    if cell is None:
        cell = ET.SubElement(row, Q('c'), {'r': address})
    cell.clear()
    cell.set('r', address)
    cell.set('t', 'str' if isinstance(value, str) else 'n')
    if formula:
        ET.SubElement(cell, Q('f')).text = formula
    ET.SubElement(cell, Q('v')).text = str(value)


def row(sheet, number, values):
    for index, value in enumerate(values):
        set_cell(sheet, f'{chr(65 + index)}{number}', value)


def create(name, change):
    with zipfile.ZipFile(SOURCE) as archive:
        files = {p: archive.read(p) for p in archive.namelist()}
    sheets = {i: ET.fromstring(files[f'xl/worksheets/sheet{i}.xml']) for i in range(1, 16)}
    change(sheets)
    for i, sheet in sheets.items():
        files[f'xl/worksheets/sheet{i}.xml'] = ET.tostring(sheet, encoding='utf-8', xml_declaration=True)
    with zipfile.ZipFile(DEST / f'{name}.xlsx', 'w', zipfile.ZIP_DEFLATED) as archive:
        for p, data in files.items():
            archive.writestr(p, data)


def modified(s):
    set_cell(s[3], 'D5', '正式地点测试：档案室')
    set_cell(s[6], 'I5', '第一行：甲🙂乙\n第二行：直接编辑后由程序读取。')
    row(s[3], 6, ['', 'true', 'ROOM2', '第二地点'])
    row(s[9], 8, ['', 'true', 'ROOM2_ENTRY', 'ROOM2', '调查第二地点', '第二地点的正文。', 'ALWAYS', 'SRC_ROOM2', 'CABINET', '', '', ''])
    row(s[15], 5, ['', 'true', 'LINK_OUT', 'ROOM', 'ROOM2', '前往第二地点', 'ALWAYS'])
    row(s[15], 6, ['', 'true', 'LINK_BACK', 'ROOM2', 'ROOM', '返回调查室', 'ALWAYS'])
    row(s[15], 7, ['', 'true', 'LINK_LOCKED', 'ROOM', 'ROOM2', '尚未开放的路线', 'Q1_DONE'])
    row(s[5], 20, ['', 'false', 'BROKEN_DISABLED', 'not-a-type'])
    row(s[5], 25, ['#作者备注', 'true', 'IGNORED', 'not-a-type'])
    row(s[5], 220, ['', 'true', 'LATE_ROW', 'testimony'])
    # 分支内为与，分支间为或。
    row(s[10], 12, ['', 'true', 'COND_OR', 1, 1, 'heard', 'S1'])
    row(s[10], 13, ['', 'true', 'COND_OR', 2, 1, 'owned', 'B1'])
    row(s[10], 14, ['', 'true', 'COND_AND', 1, 1, 'heard', 'S1'])
    row(s[10], 15, ['', 'true', 'COND_AND', 1, 2, 'owned', 'B1'])


def inline_strings(s):
    for sheet in s.values():
        for cell in sheet.iter(Q('c')):
            if cell.get('t') != 'str':
                continue
            value = cell.find(Q('v'))
            text = value.text if value is not None else ''
            if value is not None:
                cell.remove(value)
            cell.set('t', 'inlineStr')
            container = ET.SubElement(cell, Q('is'))
            ET.SubElement(container, Q('t'), {'{http://www.w3.org/XML/1998/namespace}space': 'preserve'}).text = text


def make_shared():
    with zipfile.ZipFile(SOURCE) as archive:
        files = {p: archive.read(p) for p in archive.namelist()}
    strings = []
    for p in list(files):
        if not p.startswith('xl/worksheets/sheet') or not p.endswith('.xml'):
            continue
        sheet = ET.fromstring(files[p])
        for cell in sheet.iter(Q('c')):
            if cell.get('t') != 'str':
                continue
            value = cell.find(Q('v'))
            if value is None:
                continue
            strings.append(value.text or '')
            value.text = str(len(strings) - 1)
            cell.set('t', 's')
        files[p] = ET.tostring(sheet, encoding='utf-8', xml_declaration=True)
    table = ET.Element(Q('sst'), {'count': str(len(strings)), 'uniqueCount': str(len(strings))})
    for text in strings:
        si = ET.SubElement(table, Q('si'))
        # 富文本分成两段，阅读器须拼回完整中文与多行。
        mid = len(text) // 2
        for part in [text[:mid], text[mid:]]:
            ET.SubElement(ET.SubElement(si, Q('r')), Q('t')).text = part
    files['xl/sharedStrings.xml'] = ET.tostring(table, encoding='utf-8', xml_declaration=True)
    with zipfile.ZipFile(DEST / 'shared.xlsx', 'w', zipfile.ZIP_DEFLATED) as archive:
        for p, data in files.items():
            archive.writestr(p, data)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    create('modified', modified)
    create('inline', inline_strings)
    make_shared()
    create('duplicate', lambda s: row(s[5], 20, ['', 'true', 'A', 'evidence']))
    create('missing_ref', lambda s: set_cell(s[8], 'K5', 'MISSING_NODE'))
    create('formula', lambda s: set_cell(s[6], 'I5', 'cached text', '"cached text"'))
    create('bad_header', lambda s: set_cell(s[5], 'D2', 'changed_machine_key'))
    create('broken_inference', lambda s: set_cell(s[11], 'I5', 'MISSING_NODE'))
    create('bad_collect', lambda s: set_cell(s[11], 'N5', ''))
    create('basis_cycle', lambda s: row(s[14], 7, ['', 'true', 'R_ONE', 1, 'R_Q2_R_ONE']))
    print('Created 10 local XLSX input fixtures.')


if __name__ == '__main__':
    main()
