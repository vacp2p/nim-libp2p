import os
import glob
import csv
import statistics
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse_csv(filepath):
    timestamps = []
    cpu_percent = []
    mem_usage_mb = []
    download_MBps = []
    upload_MBps = []
    download_MB = []
    upload_MB = []
    with open(filepath, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            timestamps.append(float(row["timestamp"]))
            cpu_percent.append(float(row["cpu_percent"]))
            mem_usage_mb.append(float(row["mem_usage_mb"]))
            download_MBps.append(float(row["download_MBps"]))
            upload_MBps.append(float(row["upload_MBps"]))
            download_MB.append(float(row["download_MB"]))
            upload_MB.append(float(row["upload_MB"]))
    return {
        "timestamps": timestamps,
        "cpu_percent": cpu_percent,
        "mem_usage_mb": mem_usage_mb,
        "download_MBps": download_MBps,
        "upload_MBps": upload_MBps,
        "download_MB": download_MB,
        "upload_MB": upload_MB,
    }


def plot_metrics(data, title, output_path):
    timestamps = data["timestamps"]
    time_points = [t - timestamps[0] for t in timestamps]
    cpu = data["cpu_percent"]
    mem = data["mem_usage_mb"]
    download_MBps = data["download_MBps"]
    upload_MBps = data["upload_MBps"]
    download_MB = data["download_MB"]
    upload_MB = data["upload_MB"]

    cpu_median = statistics.median(cpu)
    cpu_max = max(cpu)
    mem_median = statistics.median(mem)
    mem_max = max(mem)
    download_MBps_median = statistics.median(download_MBps)
    download_MBps_max = max(download_MBps)
    upload_MBps_median = statistics.median(upload_MBps)
    upload_MBps_max = max(upload_MBps)
    download_MB_total = download_MB[-1]
    upload_MB_total = upload_MB[-1]

    fig, (ax1, ax2, ax3, ax4) = plt.subplots(4, 1, figsize=(12, 16), sharex=True)
    fig.suptitle(title, fontsize=16)

    # CPU Usage
    ax1.plot(time_points, cpu, "b-", label=f"CPU Usage (%)\nmedian = {cpu_median:.2f}\nmax = {cpu_max:.2f}")
    ax1.set_ylabel("CPU Usage (%)")
    ax1.set_title("CPU Usage Over Time")
    ax1.grid(True)
    ax1.set_xlim(left=0)
    ax1.set_ylim(bottom=0)
    ax1.legend(loc="best")

    # Memory Usage
    ax2.plot(time_points, mem, "m-", label=f"Memory Usage (MB)\nmedian = {mem_median:.2f} MB\nmax = {mem_max:.2f} MB")
    ax2.set_ylabel("Memory Usage (MB)")
    ax2.set_title("Memory Usage Over Time")
    ax2.grid(True)
    ax2.set_xlim(left=0)
    ax2.set_ylim(bottom=0)
    ax2.legend(loc="best")

    # Network Throughput
    ax3.plot(
        time_points,
        download_MBps,
        "c-",
        label=f"Download (MB/s)\nmedian = {download_MBps_median:.2f} MB/s\nmax = {download_MBps_max:.2f} MB/s",
        linewidth=2,
    )
    ax3.plot(
        time_points, upload_MBps, "r-", label=f"Upload (MB/s)\nmedian = {upload_MBps_median:.2f} MB/s\nmax = {upload_MBps_max:.2f} MB/s", linewidth=2
    )
    ax3.set_ylabel("Network Throughput (MB/s)")
    ax3.set_title("Network Activity Over Time")
    ax3.grid(True)
    ax3.set_xlim(left=0)
    ax3.set_ylim(bottom=0)
    ax3.legend(loc="best", labelspacing=2)

    # Accumulated Network Data
    ax4.plot(time_points, download_MB, "c-", label=f"Download (MB), total: {download_MB_total:.2f} MB", linewidth=2)
    ax4.plot(time_points, upload_MB, "r-", label=f"Upload (MB), total: {upload_MB_total:.2f} MB", linewidth=2)
    ax4.set_xlabel("Time (seconds)")
    ax4.set_ylabel("Total Data Transferred (MB)")
    ax4.set_title("Accumulated Network Data Over Time")
    ax4.grid(True)
    ax4.set_xlim(left=0)
    ax4.set_ylim(bottom=0)
    ax4.legend(loc="best")

    plt.tight_layout(rect=(0, 0, 1, 1))
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    plt.savefig(output_path, dpi=100, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved plot to {output_path}")


if __name__ == "__main__":
    shared_volume_path = os.environ.get("SHARED_VOLUME_PATH", "performance/output")
    docker_stats_prefix = os.environ.get("DOCKER_STATS_PREFIX", "docker_stats_")
    glob_pattern = os.path.join(shared_volume_path, f"{docker_stats_prefix}*.csv")
    csv_files = glob.glob(glob_pattern)
    for csv_file in csv_files:
        file_name = os.path.splitext(os.path.basename(csv_file))[0]
        data = parse_csv(csv_file)
        plot_metrics(data, title=file_name, output_path=os.path.join(shared_volume_path, f"{file_name}.png"))
