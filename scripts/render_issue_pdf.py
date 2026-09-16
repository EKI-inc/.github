"""Render a GitHub issue event payload to a simple PDF attachment."""

from __future__ import annotations

import argparse
import json
import textwrap
from pathlib import Path
from typing import Any


PAGE_WIDTH = 612
PAGE_HEIGHT = 792
MARGIN = 54
LINE_HEIGHT = 13
FONT_SIZE = 10
TITLE_FONT_SIZE = 15


def escape_pdf_text(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def wrap_text(value: str, width: int = 88) -> list[str]:
    lines: list[str] = []
    for raw_line in value.splitlines() or [""]:
        if not raw_line.strip():
            lines.append("")
            continue
        lines.extend(textwrap.wrap(raw_line, width=width, replace_whitespace=False))
    return lines


def issue_lines(event: dict[str, Any]) -> list[str]:
    issue = event.get("issue", {})
    repository = event.get("repository", {})
    labels = ", ".join(label.get("name", "") for label in issue.get("labels", []))
    assignees = ", ".join(user.get("login", "") for user in issue.get("assignees", []))
    user = issue.get("user", {}).get("login", "")

    lines = [
        f"Project Intake Issue #{issue.get('number', '')}",
        "",
        f"Title: {issue.get('title', '')}",
        f"Repository: {repository.get('full_name', '')}",
        f"URL: {issue.get('html_url', '')}",
        f"Submitted by: @{user}" if user else "Submitted by:",
        f"Created: {issue.get('created_at', '')}",
        f"Labels: {labels}",
        f"Assignees: {assignees}",
        "",
        "Issue Body",
        "",
    ]
    lines.extend(wrap_text(issue.get("body") or "(No body provided.)"))
    return lines


def paginate(lines: list[str], lines_per_page: int) -> list[list[str]]:
    return [lines[index : index + lines_per_page] for index in range(0, len(lines), lines_per_page)]


def build_pdf(lines: list[str]) -> bytes:
    lines_per_page = int((PAGE_HEIGHT - (MARGIN * 2)) / LINE_HEIGHT)
    pages = paginate(lines, lines_per_page)
    objects: list[bytes] = []

    def add_object(content: bytes) -> int:
        objects.append(content)
        return len(objects)

    catalog_id = add_object(b"<< /Type /Catalog /Pages 2 0 R >>")
    pages_id = add_object(b"")
    font_id = add_object(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids: list[int] = []

    for page_index, page_lines in enumerate(pages, start=1):
        commands = ["BT", f"/F1 {FONT_SIZE} Tf", f"{MARGIN} {PAGE_HEIGHT - MARGIN} Td"]
        for line_index, line in enumerate(page_lines):
            if line_index == 0 and page_index == 1:
                commands.append(f"/F1 {TITLE_FONT_SIZE} Tf")
            elif line_index == 1 and page_index == 1:
                commands.append(f"/F1 {FONT_SIZE} Tf")
            if line_index:
                commands.append(f"0 -{LINE_HEIGHT} Td")
            commands.append(f"({escape_pdf_text(line)}) Tj")
        commands.append("ET")
        stream = "\n".join(commands).encode("utf-8")
        content_id = add_object(
            b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"\nendstream"
        )
        page_id = add_object(
            (
                f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 {PAGE_WIDTH} {PAGE_HEIGHT}] "
                f"/Resources << /Font << /F1 {font_id} 0 R >> >> /Contents {content_id} 0 R >>"
            ).encode("ascii")
        )
        page_ids.append(page_id)

    objects[pages_id - 1] = (
        f"<< /Type /Pages /Kids [{' '.join(f'{page_id} 0 R' for page_id in page_ids)}] "
        f"/Count {len(page_ids)} >>"
    ).encode("ascii")

    output = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for object_id, content in enumerate(objects, start=1):
        offsets.append(len(output))
        output.extend(f"{object_id} 0 obj\n".encode("ascii"))
        output.extend(content)
        output.extend(b"\nendobj\n")

    xref_start = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    output.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root {catalog_id} 0 R >>\n"
            f"startxref\n{xref_start}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-json", required=True, help="Path to the GitHub event JSON payload.")
    parser.add_argument("--output", required=True, help="PDF output path.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    event = json.loads(Path(args.event_json).read_text(encoding="utf-8-sig"))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(build_pdf(issue_lines(event)))
    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
