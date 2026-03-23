#!/usr/bin/env python3
"""
Post AI review results as a GitLab Merge Request comment.
Reads .opencode/review_result.json and posts formatted Markdown to the MR.

Environment variables required:
  - GITLAB_API_URL: GitLab API base URL (e.g., https://gitlab.example.com/api/v4)
  - MR_PROJECT_ID: GitLab project ID
  - MR_IID: Merge request internal ID
  - PRIVATE_TOKEN: GitLab API token with comment permissions
"""

import json
import os
import sys
import requests

RESULT_FILE = ".opencode/review_result.json"
OVERRIDE_COMMAND = "/ai-review-override"


def load_result():
    """Load and validate the review result JSON."""
    try:
        with open(RESULT_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[ERROR] Failed to load {RESULT_FILE}: {e}")
        return None


def check_override(api_url, project_id, mr_iid, token):
    """Check if a tech lead has posted an override command in MR notes."""
    url = f"{api_url}/projects/{project_id}/merge_requests/{mr_iid}/notes"
    headers = {"PRIVATE-TOKEN": token}

    try:
        resp = requests.get(url, headers=headers, params={"per_page": 100})
        resp.raise_for_status()
        notes = resp.json()

        for note in notes:
            body = note.get("body", "")
            if OVERRIDE_COMMAND in body:
                author = note.get("author", {}).get("username", "unknown")
                return True, author, body
    except requests.RequestException as e:
        print(f"[WARN] Failed to check override notes: {e}")

    return False, None, None


def format_comment(result, overridden=False, override_author=None):
    """Format the review result as a Markdown MR comment."""
    lines = []
    lines.append("## 🤖 AI Code Review")
    lines.append("")

    if overridden:
        lines.append(
            f"> ⚠️ **CRITICAL findings were overridden by @{override_author}**"
        )
        lines.append("")

    summary = result.get("summary", "No summary available.")
    lines.append(f"**Summary**: {summary}")
    lines.append("")

    findings = result.get("findings", [])
    critical = [f for f in findings if f.get("severity") == "CRITICAL"]
    warnings = [f for f in findings if f.get("severity") == "WARNING"]
    infos = [f for f in findings if f.get("severity") == "INFO"]

    # CRITICAL
    if critical:
        lines.append("### 🔴 CRITICAL（需修复后方可合并）")
        lines.append("")
        for f in critical:
            loc = f.get("file", "")
            if f.get("line"):
                loc += f":{f['line']}"
            category = f.get("category", "")
            message = f.get("message", "")
            suggestion = f.get("suggestion", "")
            spec_ref = f.get("spec_reference", "")

            lines.append(f"- **[{category}]** `{loc}`")
            lines.append(f"  {message}")
            if spec_ref:
                lines.append(f"  📖 Spec: {spec_ref}")
            if suggestion:
                lines.append(f"  💡 **建议**: {suggestion}")
            lines.append("")

    # WARNING
    if warnings:
        lines.append("### ⚠️ WARNING")
        lines.append("")
        for f in warnings:
            loc = f.get("file", "")
            if f.get("line"):
                loc += f":{f['line']}"
            category = f.get("category", "")
            message = f.get("message", "")
            suggestion = f.get("suggestion", "")
            spec_ref = f.get("spec_reference", "")

            lines.append(f"- **[{category}]** `{loc}`")
            lines.append(f"  {message}")
            if spec_ref:
                lines.append(f"  📖 Spec: {spec_ref}")
            if suggestion:
                lines.append(f"  💡 {suggestion}")
            lines.append("")

    # INFO
    if infos:
        lines.append(
            "<details><summary>ℹ️ INFO（"
            + str(len(infos))
            + " 条信息性建议）</summary>"
        )
        lines.append("")
        for f in infos:
            loc = f.get("file", "")
            if f.get("line"):
                loc += f":{f['line']}"
            message = f.get("message", "")
            suggestion = f.get("suggestion", "")

            lines.append(f"- `{loc}` {message}")
            if suggestion:
                lines.append(f"  💡 {suggestion}")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    # Spec update notice
    if result.get("spec_update_needed"):
        details = result.get("spec_update_details", "")
        lines.append("### 📝 Spec 更新提醒")
        lines.append("")
        lines.append(f"{details}")
        lines.append("")

    # No findings
    if not findings:
        lines.append("✅ 未发现问题。代码变更与 spec 一致。")
        lines.append("")

    # Footer
    lines.append("---")
    if critical and not overridden:
        lines.append(
            f"*如需覆盖 CRITICAL 阻断，tech lead 请回复 "
            f"`{OVERRIDE_COMMAND} reason: <说明>`*"
        )
    lines.append(
        f"*Model: `{os.getenv('OPENCODE_MODEL', 'openrouter/anthropic/claude-sonnet-4.6')}`*"
    )

    return "\n".join(lines)


def post_comment(api_url, project_id, mr_iid, token, body):
    """Post a comment on the MR."""
    url = f"{api_url}/projects/{project_id}/merge_requests/{mr_iid}/notes"
    headers = {"PRIVATE-TOKEN": token}
    data = {"body": body}

    try:
        resp = requests.post(url, headers=headers, json=data)
        resp.raise_for_status()
        print(f"[OK] Posted review comment to MR !{mr_iid}")
        return True
    except requests.RequestException as e:
        print(f"[ERROR] Failed to post comment: {e}")
        if hasattr(e, "response") and e.response is not None:
            print(f"  Response: {e.response.text[:500]}")
        return False


def main():
    # Load environment
    api_url = os.getenv("GITLAB_API_URL", "")
    project_id = os.getenv("MR_PROJECT_ID", "")
    mr_iid = os.getenv("MR_IID", "")
    token = os.getenv("PRIVATE_TOKEN", "")

    if not all([api_url, project_id, mr_iid, token]):
        print("[WARN] Missing GitLab environment variables. Skipping comment posting.")
        print(f"  GITLAB_API_URL={bool(api_url)}, MR_PROJECT_ID={bool(project_id)}, "
              f"MR_IID={bool(mr_iid)}, PRIVATE_TOKEN={bool(token)}")
        sys.exit(0)

    # Load result
    result = load_result()
    if result is None:
        print("[WARN] No review result to post.")
        sys.exit(0)

    # Check for override
    findings = result.get("findings", [])
    has_critical = any(f.get("severity") == "CRITICAL" for f in findings)

    overridden = False
    override_author = None
    if has_critical:
        overridden, override_author, _ = check_override(
            api_url, project_id, mr_iid, token
        )
        if overridden:
            print(f"[INFO] Override found from @{override_author}. "
                  f"CRITICAL findings will not block.")

    # Format and post
    comment = format_comment(result, overridden, override_author)
    post_comment(api_url, project_id, mr_iid, token, comment)


if __name__ == "__main__":
    main()
