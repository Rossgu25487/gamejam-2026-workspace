"""只读导入策划 XLSX；四行表头、scope 和真实类型共同决定导出。"""
import json
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def read_tables(path):
    with zipfile.ZipFile(path) as archive:
        shared = []
        if 'xl/sharedStrings.xml' in archive.namelist():
            shared = [''.join(t.text or '' for t in si.findall('.//s:t', NS)) for si in ET.fromstring(archive.read('xl/sharedStrings.xml'))]
        relations = {r.attrib['Id']: r.attrib['Target'] for r in ET.fromstring(archive.read('xl/_rels/workbook.xml.rels'))}
        tables = {}
        for sheet in ET.fromstring(archive.read('xl/workbook.xml')).findall('.//s:sheet', NS):
            target = relations[sheet.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
            target = target.lstrip('/') if target.startswith('/') else 'xl/' + target
            rows = []
            for row in ET.fromstring(archive.read(target)).findall('.//s:row', NS):
                data = {}
                for cell in row.findall('s:c', NS):
                    column = ''.join(x for x in cell.attrib['r'] if x.isalpha())
                    value = cell.find('s:v', NS)
                    text = value.text if value is not None else ''.join(t.text or '' for t in cell.findall('.//s:t', NS))
                    data[column] = shared[int(text)] if cell.attrib.get('t') == 's' else text
                rows.append(data)
            tables[sheet.attrib['name']] = rows
        return tables


def typed_rows(rows):
    if len(rows) < 4 or rows[1].get('A') != '##var':
        return []
    result = []
    for row in rows[4:]:
        record = {}
        for col, key in rows[1].items():
            if col == 'A' or not key or key.startswith('#'):
                continue
            value = row.get(col, '')
            if value != '':
                kind = rows[2].get(col, 'string')
                if kind in ('int', 'long'):
                    value = int(value)
                elif kind in ('float', 'double'):
                    value = float(value)
                elif kind == 'bool':
                    if str(value).lower() not in ('1', '0', 'true', 'false'):
                        raise ValueError(f'Invalid boolean: {value}')
                    value = str(value).lower() in ('1', 'true')
            record[key] = value
        if record.get('data_scope', 'runtime') != 'runtime':
            continue
        if record.get('enabled') is False:
            continue
        result.append(record)
    return result


def main():
    source = ROOT / 'game/代码开发需求'
    tables = read_tables(source / '核心玩法系统/核心玩法系统配置表.xlsx')
    rules = {name: typed_rows(rows) for name, rows in tables.items() if not name.startswith('##')}
    defaults = rules['核心总控'][0]
    assert [defaults[k] for k in ('slot_count', 'bar_page_size', 'grid_columns', 'grid_visible_rows')] == [2, 5, 6, 2]
    assert defaults['single_material_sufficient'] and not defaults['material_consumed']
    text_tables = read_tables(source / '游戏初始化与开始系统/游戏初始化与开始系统配置表.xlsx')
    texts = typed_rows(text_tables['功能文字'])
    dest = ROOT / 'game/data/core'
    dest.mkdir(parents=True, exist_ok=True)
    (dest / 'rules.json').write_text(json.dumps(rules, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (dest / 'function_text.json').write_text(json.dumps(texts, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Imported {len(rules)} rule tables and {len(texts)} function texts; test rows excluded.')


if __name__ == '__main__':
    main()
