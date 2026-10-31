from io import BytesIO
from xml.etree import ElementTree as ET
from zipfile import ZipFile

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.voice_xlsx import NS, workbook_bytes


def test_xlsx_preserves_unicode_ids_and_formula_like_text():
    rows = [["001", '=HYPERLINK("test")', "日本語 <台呼> & 中文字幕\n第二行"]]
    with ZipFile(BytesIO(workbook_bytes(["序号", "内容", "中文字幕"], rows))) as z:
        assert z.testzip() is None
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        cells = sheet.findall(f"{{{NS}}}sheetData/{{{NS}}}row/{{{NS}}}c")
        assert all(c.attrib["t"] == "inlineStr" for c in cells)
        assert [c.find(f"{{{NS}}}is/{{{NS}}}t").text for c in cells[3:]] == rows[0]
        assert not sheet.findall(f".//{{{NS}}}f")
        assert sheet.find(f".//{{{NS}}}pane").attrib["state"] == "frozen"
        assert sheet.find(f"{{{NS}}}autoFilter").attrib["ref"] == "A1:C2"
        for name in z.namelist():
            if name.endswith((".xml", ".rels")):
                ET.fromstring(z.read(name))


def test_xlsx_rejects_truncation_instead_of_losing_text():
    with pytest.raises(CliError, match="TXT"):
        workbook_bytes(["内容"], [["日" * 32768]])


def test_xlsx_empty_export_is_still_valid():
    with ZipFile(BytesIO(workbook_bytes(["序号", "文本"], []))) as z:
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        assert sheet.find(f"{{{NS}}}autoFilter").attrib["ref"] == "A1:B1"
