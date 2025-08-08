import os
import glob
import csv
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def extract_pr_number(filename):
    """Extract PR number from filename of format pr{number}_anything.csv"""
    fname = os.path.basename(filename)
    parts = fname.split("_", 1)
    pr_str = parts[0][2:]
    if not pr_str.isdigit():
        return None
    return int(pr_str)


def parse_latency_csv(csv_files):
    pr_numbers = []
    scenario_data = {}  # scenario -> {pr_num: {min, avg, max}}
    for csv_file in csv_files:
        pr_num = extract_pr_number(csv_file)
        if pr_num is None:
            continue
        pr_numbers.append(pr_num)
        with open(csv_file, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                scenario = row["Scenario"]
                if scenario not in scenario_data:
                    scenario_data[scenario] = {}
                scenario_data[scenario][pr_num] = {
                    "min": float(row["MinLatencyMs"]),
                    "avg": float(row["AvgLatencyMs"]),
                    "max": float(row["MaxLatencyMs"]),
                }
    pr_numbers = sorted(set(pr_numbers))
    return pr_numbers, scenario_data


def plot_latency_history(pr_numbers, scenario_data, output_path):
    num_scenarios = len(scenario_data)
    fig, axes = plt.subplots(num_scenarios, 1, figsize=(14, 4 * num_scenarios), sharex=True)
    if num_scenarios == 1:
        axes = [axes]

    color_map = plt.colormaps.get_cmap("tab10")

    for i, (scenario, pr_stats) in enumerate(scenario_data.items()):
        ax = axes[i]
        min_vals = [pr_stats.get(pr, {"min": None})["min"] for pr in pr_numbers]
        avg_vals = [pr_stats.get(pr, {"avg": None})["avg"] for pr in pr_numbers]
        max_vals = [pr_stats.get(pr, {"max": None})["max"] for pr in pr_numbers]

        color = color_map(i % color_map.N)

        if any(v is not None for v in avg_vals):
            ax.plot(pr_numbers, avg_vals, marker="o", label="Avg Latency (ms)", color=color)
            ax.fill_between(pr_numbers, min_vals, max_vals, color=color, alpha=0.2, label="Min-Max Latency (ms)")
            for pr, avg, minv, maxv in zip(pr_numbers, avg_vals, min_vals, max_vals):
                if avg is not None:
                    ax.scatter(pr, avg, color=color)
                    ax.text(pr, avg, f"{avg:.1f}", fontsize=14, ha="center", va="bottom")
                if minv is not None and maxv is not None:
                    ax.vlines(pr, minv, maxv, color=color, alpha=0.5)

            ax.set_ylabel("Latency (ms)")
            ax.set_title(f"Scenario: {scenario}")
            ax.legend(loc="upper left", fontsize="small")
            ax.grid(True, linestyle="--", alpha=0.5)

    # Set X axis ticks and labels to show all PR numbers as 'PR <number>'
    axes[-1].set_xlabel("PR Number")
    axes[-1].set_xticks(pr_numbers)
    axes[-1].set_xticklabels([f"PR {pr}" for pr in pr_numbers], rotation=45, ha="right", fontsize=14)

    plt.tight_layout()
    plt.savefig(output_path)
    print(f"Saved combined plot to {output_path}")
    plt.close(fig)


if __name__ == "__main__":
    LATENCY_HISTORY_PATH = os.environ.get("LATENCY_HISTORY_PATH", "performance/output")
    LATENCY_HISTORY_PREFIX = os.environ.get("LATENCY_HISTORY_PREFIX", "pr")
    LATENCY_HISTORY_PLOT_FILENAME = os.environ.get("LATENCY_HISTORY_PLOT_FILENAME", "pr")
    glob_pattern = os.path.join(LATENCY_HISTORY_PATH, f"{LATENCY_HISTORY_PREFIX}*_latency.csv")
    csv_files = sorted(glob.glob(glob_pattern))
    pr_numbers, scenario_data = parse_latency_csv(csv_files)
    output_path = os.path.join(LATENCY_HISTORY_PATH, LATENCY_HISTORY_PLOT_FILENAME)
    plot_latency_history(pr_numbers, scenario_data, output_path)
