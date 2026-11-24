#!/usr/bin/env python3
"""Refresh the completion comment and repository README for a project-intake issue.

Reads the issue form template to learn every field, its section, and whether it
is required, then checks which fields were answered in the issue body.
Run by .github/workflows/model-project-intake-progress.yml on issue open/edit.
Use --dry-run BODY_FILE to print the comment locally without calling GitHub.
"""
import base64
import html
import json
import os
import re
import sys
from urllib.error import HTTPError
import urllib.request

import yaml

MARKER = "<!-- intake-progress -->"
IT_ADMIN = "grodgers-eki"
INTAKE_REVIEWER = "alewis-eki"
GITHUB_MENTION = re.compile(r"(?<![\w@./-])@([a-z0-9]+(?:-[a-z0-9]+)*)(?![\w/-])", re.IGNORECASE)
README_START = "<!-- project-intake:start -->"
README_END = "<!-- project-intake:end -->"
TEMPLATE = os.environ.get("INTAKE_TEMPLATE", ".github/ISSUE_TEMPLATE/model-project-intake.yml")
EMPTY = {"", "_no response_"}


def load_fields(path):
    with open(path, encoding="utf-8") as f:
        form = yaml.safe_load(f)
    fields, section = [], "General"
    for item in form["body"]:
        attrs = item.get("attributes", {})
        if item["type"] == "markdown":
            m = re.search(r"<!--\s*section:\s*(.+?)\s*-->", attrs.get("value", ""))
            if m:
                section = m.group(1)
            continue
        fields.append({
            "label": attrs["label"].strip(),
            "type": item["type"],
            "required": bool(item.get("validations", {}).get("required", False)),
            "section": section,
        })
    return fields


def parse_body(body, labels):
    """Split the rendered issue body into {field label: answer}."""
    headings = {label: label for label in labels}
    if "Project Folder Location(s)" in labels:
        headings["Project Data Locations"] = "Project Folder Location(s)"
    answers, current = {}, None
    for line in (body or "").splitlines():
        m = re.match(r"^###\s+(.+?)\s*$", line)
        if m and m.group(1) in headings:
            current = headings[m.group(1)]
            answers[current] = []
        elif current is not None:
            answers[current].append(line)
    return {k: "\n".join(v).strip() for k, v in answers.items()}


def is_answered(field, value):
    if value is None:
        return False
    if field["type"] == "checkboxes":
        return bool(re.search(r"^\s*-\s*\[[xX]\]", value, re.M))
    normalized = value.strip().lower()
    return normalized not in EMPTY and (field["type"] != "dropdown" or normalized != "none")


def bar(pct, width=20):
    filled = round(pct / 100 * width)
    return "█" * filled + "░" * (width - filled)


def pct(done, total):
    return round(100 * done / total) if total else 100


def build_comment(fields, answers):
    for f in fields:
        f["done"] = is_answered(f, answers.get(f["label"]))
    done = sum(f["done"] for f in fields)
    req = [f for f in fields if f["required"]]
    req_done = sum(f["done"] for f in req)
    overall = pct(done, len(fields))

    lines = [
        MARKER,
        f"## 📋 Intake form completion: {overall}%",
        "",
        f"`{bar(overall)}` &nbsp; **{done} of {len(fields)}** fields answered",
        "",
    ]
    if req_done == len(req):
        lines.append(f"✅ **All required fields complete** ({req_done}/{len(req)})")
    else:
        lines.append(f"⚠️ **Required fields complete: {req_done}/{len(req)} ({pct(req_done, len(req))}%)**")
    lines += ["", "| Section | Answered | Progress |", "|:---|:---:|:---|"]

    sections = list(dict.fromkeys(f["section"] for f in fields))
    for s in sections:
        sf = [f for f in fields if f["section"] == s]
        sd = sum(f["done"] for f in sf)
        p = pct(sd, len(sf))
        lines.append(f"| {s} | {sd}/{len(sf)} | `{bar(p, 10)}` {p}% |")

    missing = [f for f in fields if not f["done"]]
    if missing:
        lines += ["", f"<details><summary>Fields still blank ({len(missing)})</summary>", ""]
        for f in missing:
            tag = " **(required)**" if f["required"] else ""
            lines.append(f"- {f['section']} → {f['label']}{tag}")
        lines += ["", "</details>"]
    lines += ["", "<sub>Updates automatically when the issue is edited.</sub>"]
    return "\n".join(lines)


def api(method, url, token, data=None):
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or "null")


def render_readme_section(fields, answers, repo, number, updated_at):
    lines = [
        README_START,
        f"<!-- intake-source: {updated_at} #{number} -->",
        "## Project intake",
        "",
        f"**Last updated (UTC)** {updated_at[:10]} · [Intake issue #{number}](https://github.com/{repo}/issues/{number})",
    ]
    section = None
    for field in fields:
        if field["section"] != section:
            section = field["section"]
            lines += ["", f"### {section}", ""]
        label = field["label"]
        answer = answers.get(label)
        lines += [f"**{label}**", ""]
        if is_answered(field, answer):
            if field["type"] == "checkboxes":
                answer = "\n".join(re.findall(r"^\s*-\s*\[[xX]\][ \t]*(.+)$", answer, re.M))
            lines.append(f"<pre>{html.escape(answer)}</pre>")
        else:
            lines.append("**Incomplete** (required)" if field["required"] else "**Incomplete**")
        lines.append("")
    return "\n".join(lines + [README_END])


def merge_readme_section(readme, section, number, updated_at):
    before, start, remainder = readme.partition(README_START)
    newline = "\r\n" if "\r\n" in readme else "\n"
    section = section.replace("\n", newline)
    if not start:
        if README_END in readme:
            raise ValueError("Invalid project intake markers in README.md")
        if readme:
            before += newline
            if not readme.endswith(newline):
                before += newline
        return before + section + newline
    current, end, after = remainder.partition(README_END)
    if not end or README_START in remainder or README_END in before + after:
        raise ValueError("Invalid project intake markers in README.md")
    source = re.search(r"^<!-- intake-source: (\S+) #(\d+) -->\r?$", current, re.M)
    if source and (source[1], int(source[2])) > (updated_at, number):
        return readme
    return before + section + after


def update_readme(repo, token, fields, answers, issue):
    number, updated_at = issue["number"], issue["updated_at"]
    section = render_readme_section(fields, answers, repo, number, updated_at)
    # Without a branch or ref, the Contents API uses the target repository's default branch.
    url = f"https://api.github.com/repos/{repo}/contents/README.md"
    for attempt in range(3):
        try:
            file = api("GET", url, token)
        except HTTPError as error:
            if error.code != 404:
                raise
            file = None
        readme = base64.b64decode(file["content"]).decode("utf-8") if file else ""
        updated = merge_readme_section(readme, section, number, updated_at)
        if updated == readme:
            return "README is current"
        data = {
            "message": f"Update project intake README from issue #{number}",
            "content": base64.b64encode(updated.encode("utf-8")).decode("ascii"),
        }
        if file:
            data["sha"] = file["sha"]
        try:
            api("PUT", url, token, data)
            return "Updated README"
        except HTTPError as error:
            if error.code != 409 or attempt == 2:
                raise


def upsert_comment(repo, number, token, body):
    base = f"https://api.github.com/repos/{repo}/issues"
    page = 1
    while True:
        comments = api("GET", f"{base}/{number}/comments?per_page=100&page={page}", token)
        for c in comments:
            if MARKER in (c.get("body") or "") and c["user"]["type"] == "Bot":
                api("PATCH", f"{base}/comments/{c['id']}", token, {"body": body})
                return "updated"
        if len(comments) < 100:
            break
        page += 1
    api("POST", f"{base}/{number}/comments", token, {"body": body})
    return "created"


def assign_intake_issue(repo, token, issue, answers):
    candidates = [issue["user"]["login"], INTAKE_REVIEWER]
    if any(answers.get(field, "").strip().casefold() == "yes"
           for field in ("HPC Cluster Required?", "Web Hosting Required?")):
        candidates.append(IT_ADMIN)
    candidates.extend(GITHUB_MENTION.findall(answers.get("Points of Contact", "")))

    existing = {user["login"].casefold() for user in issue["assignees"]}
    pending = list(dict.fromkeys(login.casefold() for login in candidates if login.casefold() not in existing))
    if not pending:
        return

    url = f"https://api.github.com/repos/{repo}/issues/{issue['number']}/assignees"
    result = api("POST", url, token, {"assignees": pending[:10]})
    assigned = {user["login"].casefold() for user in result["assignees"]}
    skipped = [login for login in pending if login not in assigned]
    if skipped:
        print("Could not assign: " + ", ".join(skipped))


def main():
    fields = load_fields(TEMPLATE)
    labels = {f["label"] for f in fields}
    if len(sys.argv) == 3 and sys.argv[1] == "--dry-run":
        body = open(sys.argv[2], encoding="utf-8").read()
        print(build_comment(fields, parse_body(body, labels)))
        return
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
        event_issue = json.load(f)["issue"]
    number = event_issue["number"]
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GITHUB_TOKEN"]
    issue = api("GET", f"https://api.github.com/repos/{repo}/issues/{number}", token)
    current_answers = parse_body(issue.get("body"), labels)
    assign_intake_issue(repo, token, issue, current_answers)
    comment = build_comment(fields, current_answers)
    print(upsert_comment(repo, number, token, comment))
    answers = parse_body(event_issue.get("body"), labels)
    print(update_readme(repo, token, fields, answers, event_issue))


if __name__ == "__main__":
    main()
