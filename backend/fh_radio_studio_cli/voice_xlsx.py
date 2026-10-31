"""Small dependency-free spreadsheet export of structured voice text rows."""

from io import BytesIO
from xml.etree import ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile

from .common import CliError

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"


def workbook_bytes(headers, rows):
    if len(rows) > 1048575:
        raise CliError("条目超过 XLSX 单表上限，请分批导出。")

    def element(parent, name, **attrs):
        return ET.SubElement(parent, f"{{{NS}}}{name}", attrs)

    sheet = ET.Element(f"{{{NS}}}worksheet")
    views = element(sheet, "sheetViews")
    view = element(views, "sheetView", workbookViewId="0")
    element(view, "pane", ySplit="1", topLeftCell="A2", activePane="bottomLeft", state="frozen")
    cols = element(sheet, "cols")
    for i, header in enumerate(headers, 1):
        width = 45 if i == 1 else 9 if header == "序号" else 14 if "时长" in header else 60
        element(cols, "col", min=str(i), max=str(i), width=str(width), customWidth="1")
    data = element(sheet, "sheetData")
    for n, values in enumerate([headers, *rows], 1):
        row = element(data, "row", r=str(n))
        for i, value in enumerate(values):
            # inlineStr preserves leading zeros and prevents formula execution.
            label, number = "", i + 1
            while number:
                number, digit = divmod(number - 1, 26)
                label = chr(65 + digit) + label
            text = str(value)
            if len(text.encode("utf-16-le")) // 2 > 32767:
                raise CliError(f"第 {n} 行文本超过 XLSX 单元格上限，请使用 TXT 导出。")
            text = "".join(c for c in text if c in "\t\n\r" or ord(c) >= 32)
            cell = element(row, "c", r=f"{label}{n}", t="inlineStr", s="1" if n == 1 else "0")
            item = element(cell, "is")
            element(
                item, "t", **{"{http://www.w3.org/XML/1998/namespace}space": "preserve"}
            ).text = text
    if headers:
        element(sheet, "autoFilter", ref=f"A1:{label}{len(rows) + 1}")
    out = BytesIO()
    with ZipFile(out, "w", ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>""",
        )
        archive.writestr(
            "_rels/.rels",
            """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""",
        )
        archive.writestr(
            "xl/workbook.xml",
            f"""<workbook xmlns="{NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="语音文本" sheetId="1" r:id="rId1"/></sheets></workbook>""",
        )
        archive.writestr(
            "xl/_rels/workbook.xml.rels",
            """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>""",
        )
        archive.writestr(
            "xl/styles.xml",
            f"""<styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf fontId="1" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>""",
        )
        archive.writestr(
            "xl/worksheets/sheet1.xml", ET.tostring(sheet, encoding="utf-8", xml_declaration=True)
        )
    return out.getvalue()
