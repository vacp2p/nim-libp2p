import os
import json
import requests
from glob import glob


def post_or_update_pr_comment(repo, pr_number, token, new_table, marker):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }
    # List comments on the PR
    comments_url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    resp = requests.get(comments_url, headers=headers)
    resp.raise_for_status()
    comments = resp.json()
    comment_id = None
    existing_body = None
    for c in comments:
        if c.get("body", "").startswith(marker):
            comment_id = c["id"]
            existing_body = c["body"]
            break
    if comment_id:
        # Append new table to existing comment
        updated_body = existing_body.strip() + "\n\n" + new_table.strip()
        patch_url = f"https://api.github.com/repos/{repo}/issues/comments/{comment_id}"
        patch_resp = requests.patch(patch_url, headers=headers, json={"body": updated_body})
        patch_resp.raise_for_status()
    else:
        # Create new comment
        post_body = marker + "\n\n" + new_table.strip()
        post_resp = requests.post(comments_url, headers=headers, json={"body": post_body})
        post_resp.raise_for_status()


def main():
    output_dir = os.path.join(os.path.dirname(__file__), "output")
    total_sent = 0
    total_received = 0
    min_latency = float("inf")
    max_latency = 0.0
    sum_avg_latency = 0.0
    valid_nodes = 0

    for file_path in glob(os.path.join(output_dir, "*.json")):
        with open(file_path) as f:
            stats = json.load(f)
        sent = int(stats.get("totalSent", 0))
        received = int(stats.get("totalReceived", 0))
        # Handle both string and float values
        min_l = float(str(stats.get("minLatency", "0")))
        max_l = float(str(stats.get("maxLatency", "0")))
        avg_l = float(str(stats.get("avgLatency", "0")))

        total_sent += sent
        total_received += received
        if min_l > 0.0 or max_l > 0.0 or avg_l > 0.0:
            if min_l < min_latency:
                min_latency = min_l
            if max_l > max_latency:
                max_latency = max_l
            sum_avg_latency += avg_l
            valid_nodes += 1

    # Compose the summary table only (for appending)
    table = []
    table.append(f"**Nodes:** `{valid_nodes}`  ")
    table.append(f"**Total messages sent:** `{total_sent}`  ")
    table.append(f"**Total messages received:** `{total_received}`  \n")
    table.append("| Latency (ms) | Min | Max | Avg |")
    table.append("|:---:|:---:|:---:|:---:|")
    if valid_nodes > 0:
        global_avg_latency = sum_avg_latency / valid_nodes
        table.append(f"| | {min_latency:.3f} | {max_latency:.3f} | {global_avg_latency:.3f} |")
    else:
        table.append("| | 0.000 | 0.000 | 0.000 | (no valid latency data)")
    table_md = "\n".join(table)

    # For GitHub summary
    markdown = "# 🏁 **Performance Summary**\n" + table_md
    print(markdown)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", "/tmp/summary.txt"), "w") as summary:
        summary.write(markdown + "\n")

    # Post or update PR comment if in PR context
    repo = os.environ.get("GITHUB_REPOSITORY")
    pr_number = os.environ.get("GITHUB_PR_NUMBER")
    token = os.environ.get("GITHUB_TOKEN")
    marker = "<!-- perf-summary-marker -->"
    if repo and pr_number and token:
        post_or_update_pr_comment(repo, pr_number, token, table_md, marker)


if __name__ == "__main__":
    main()
