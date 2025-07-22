import os
import json
from glob import glob


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

    commit_sha = os.environ.get("PR_HEAD_SHA") or os.environ.get("GITHUB_SHA", "unknown")
    output = []
    output.append("<!-- perf-summary-marker -->\n")
    output.append("# 🏁 **Performance Summary**\n")
    output.append(f"**Commit:** `{commit_sha}`  ")
    output.append(f"**Nodes:** `{valid_nodes}`  ")
    output.append(f"**Total messages sent:** `{total_sent}`  ")
    output.append(f"**Total messages received:** `{total_received}`  \n")
    output.append("| Latency (ms) | Min | Max | Avg |")
    output.append("|:---:|:---:|:---:|:---:|")
    if valid_nodes > 0:
        global_avg_latency = sum_avg_latency / valid_nodes
        output.append(f"| | {min_latency:.3f} | {max_latency:.3f} | {global_avg_latency:.3f} |")
    else:
        output.append("| | 0.000 | 0.000 | 0.000 | (no valid latency data)")
    markdown = "\n".join(output)
    print(markdown)
    # For GitHub summary
    with open(os.environ.get("GITHUB_STEP_SUMMARY", "/tmp/summary.txt"), "w") as summary:
        summary.write(markdown + "\n")
    # For PR comment
    with open("/tmp/perf-summary.md", "w") as f:
        f.write(markdown + "\n")


if __name__ == "__main__":
    main()
