#!/usr/bin/env python3
import os
import pandas as pd
import matplotlib.pyplot as plt
import re

plt.style.use("seaborn-v0_8-whitegrid")

# ============================================================
# Helper to safely load CSV
# ============================================================
def safe_read_csv(path):
    if os.path.exists(path):
        print(f"[+] Loaded {path}")
        return pd.read_csv(path)
    else:
        print(f"[!] Missing {path}")
        return pd.DataFrame()

# ============================================================
# Clean scenario names for better visuals
# ============================================================
def shorten_name(name: str):
    """
    Convert experiment folder names into readable short names.
    Examples:
      bw3Mbps_multiflow_10_RED_BBR  -> 3M multi(10) RED BBR
      bw3Mbps_multiflow_pfifo_BBR   -> 3M multi(5) pfifo BBR
      bwNORMAL_oneflow_pfifo        -> norm one pfifo
      bwNORMAL_multiflow_10_RED     -> norm multi(10) RED
    """
    name = name.replace("bw", "")
    name = name.replace("Mbps", "M")

    name = name.replace("NORMAL", "norm")
    name = name.replace("multiflow_10", "multi(10)")
    name = name.replace("multiflow", "multi(5)")
    name = name.replace("oneflow", "one")

    # Replace queue/CC names for consistency
    name = name.replace("pfifo", "fifo")

    # Normalize spaces
    name = name.replace("_", " ")
    name = re.sub(r"\s+", " ", name).strip()

    return name


# Small helper to compute bar height based on number of rows to avoid label overlap
def compute_bar_height(n_rows, base=0.55):
    """
    Compute a reasonable bar thickness for horizontal bar charts.
    - For small number of rows, return the base thickness.
    - For many rows, reduce thickness but keep a minimum so bars are visible.
    """
    if n_rows <= 8:
        return base
    return max(0.20, base * 8.0 / float(n_rows))


# ============================================================
# PLOT 1: PCAP metrics (RTT, CWND, GAP)
# ============================================================
def plot_pcap_summary(pcap_csv):
    df = safe_read_csv(pcap_csv)
    if df.empty:
        print("[!] No data for pcap metrics.")
        return

    # New global pcap format (no 'protocol' column)
    if "protocol" in df.columns:
        df["short_name"] = df["scenario"].apply(shorten_name) + " (" + df["protocol"] + ")"
    else:
        df["short_name"] = df["scenario"].apply(shorten_name)

    # Build a 'pair key' by removing queue token (fifo/red) so pfifo vs RED pair together.
    def pair_key_from_short(s):
        k = s.lower()
        # remove common queue tokens 'fifo' or 'red' (extend if you have other queue names)
        k = re.sub(r'\b(pfifo|pfifo_bbr|fifo|red)\b', '', k)
        k = re.sub(r'\s+', ' ', k).strip()
        return k

    df["pair_key"] = df["short_name"].apply(pair_key_from_short)

    # Map each unique pair_key to a color from a colormap
    unique_keys = list(dict.fromkeys(df["pair_key"].tolist()))  # preserve order
    cmap = plt.get_cmap("tab20")
    color_map = {k: cmap(i % 20) for i, k in enumerate(unique_keys)}

    # make a nicer display name for legend (shorter)
    def pretty_pair_name(k):
        # re-capitalize and remove duplicate spaces, keep it short
        p = k.replace("multi(5)", "multi5").replace("multi(10)", "multi10")
        p = re.sub(r'\s+', ' ', p).strip()
        return p

    pair_display = {k: pretty_pair_name(k) for k in unique_keys}

    # adapt columns based on your global file
    metrics = ["gap_avg_ms", "ack_interval_avg_ms", "ss_avg_rtt_ms", "ss_avg_cwnd"]
    labels = [
        "Gap avg (ms)",
        "ACK interval avg (ms)",
        "ss Avg RTT (ms)",
        "ss Avg CWND"
    ]

    # dynamic figure height: more scenarios => cao hơn
    n_scenarios = len(df)
    n_metrics = len(metrics)
    fig_h = max(8, 2.2 * n_metrics + 0.25 * n_scenarios)  # tăng khoảng cách
    fig, axes = plt.subplots(n_metrics, 1, figsize=(12, fig_h))

    # ensure axes is iterable
    if n_metrics == 1:
        axes = [axes]

    for i, (metric, label) in enumerate(zip(metrics, labels)):
        ax = axes[i]
        if metric not in df.columns:
            print(f"[!] Missing column: {metric}")
            continue

        df_sorted = df.sort_values(metric, ascending=False).reset_index(drop=True)

        # compute colors for each row according to pair_key
        bar_colors = [color_map.get(k, "steelblue") for k in df_sorted["pair_key"]]

        # compute dynamic bar height based on number of scenarios (tăng độ dày bar)
        bar_height = compute_bar_height(n_scenarios, base=0.7)  # tăng base từ 0.55 lên 0.7

        # draw bars with per-bar color and dynamic height
        bars = ax.barh(df_sorted["short_name"], df_sorted[metric], color=bar_colors, height=bar_height)

        # tăng font size của y tick labels và giảm rotation để dễ đọc hơn
        ax.tick_params(axis="y", labelsize=8)  # tăng từ 8 lên 9

        ax.set_xlabel(label, fontsize=13)
        ax.set_ylabel("Scenario", fontsize=11)
        ax.set_title(f"{label} by Scenario", fontsize=13, weight="bold")
        ax.grid(True, linestyle="--", alpha=0.5)

        # numeric labels on right
        for bar in bars:
            width = bar.get_width()
            ax.text(
                width * 1.02,
                bar.get_y() + bar.get_height() / 2,
                f"{width:.2f}",
                va="center",
                fontsize=8,
            )

    # Create a single legend for the figure (pairs) to avoid duplicates in each subplot
    from matplotlib.patches import Patch
    legend_handles = [Patch(color=color_map[k], label=pair_display[k]) for k in unique_keys]
    if legend_handles:
        # place legend to the right center of the figure
        fig.legend(handles=legend_handles, title="Pairs", loc="center right", bbox_to_anchor=(1.02, 0.5), fontsize=8)

    plt.tight_layout(pad=2.5, rect=(0, 0, 0.85, 1.0))  # tăng padding tổng thể
    # tăng khoảng cách giữa các subplots để labels không bị chen chúc
    plt.subplots_adjust(hspace=0.8)  # tăng từ 0.6 lên 0.8
    plt.savefig("pcap_plot.png", dpi=250, bbox_inches="tight")
    print("[+] Saved pcap_plot.png")

# ============================================================
# PLOT 2: TCP (avg BW, Fairness, Retrans) + UDP (avg BW, Jitter, Loss)
# ============================================================
def plot_bw_summary(bw_csv):
    df = safe_read_csv(bw_csv)
    if df.empty:
        print("[!] No data for bandwidth metrics.")
        return

    df["short_name"] = df["scenario"].apply(shorten_name)

    # Build a 'pair key' by removing queue token (fifo/red) so pfifo vs RED pair together.
    def pair_key_from_short(s):
        k = s.lower()
        # remove common queue tokens 'fifo' or 'red' (extend if you have other queue names)
        k = re.sub(r'\b(pfifo|pfifo_bbr|fifo|red)\b', '', k)
        k = re.sub(r'\s+', ' ', k).strip()
        return k

    df["pair_key"] = df["short_name"].apply(pair_key_from_short)

    # Map each unique pair_key to a color from a colormap
    unique_keys = list(dict.fromkeys(df["pair_key"].tolist()))  # preserve order
    cmap = plt.get_cmap("tab20")
    color_map = {k: cmap(i % 20) for i, k in enumerate(unique_keys)}

    # make a nicer display name for legend (shorter)
    def pretty_pair_name(k):
        # re-capitalize and remove duplicate spaces, keep it short
        p = k.replace("multi(5)", "multi5").replace("multi(10)", "multi10")
        p = re.sub(r'\s+', ' ', p).strip()
        return p

    pair_display = {k: pretty_pair_name(k) for k in unique_keys}

    # Updated metrics (using avg BW instead of total BW)
    metrics = [
        ("tcp_avg_bw_Mbps", "TCP Average Bandwidth (Mbps)", "seagreen"),
        ("tcp_fairness", "TCP Fairness", "teal"),
        ("tcp_avg_retrans", "TCP Retransmissions", "royalblue"),
        ("udp_avg_bw_Mbps", "UDP Average Bandwidth (Mbps)", "darkorange"),
        ("udp_avg_jitter_ms", "UDP Avg Jitter (ms)", "darkred"),
        ("udp_avg_lost_pct", "UDP Avg Packet Loss (%)", "firebrick"),
    ]

    n = len(metrics)
    fig, axes = plt.subplots(nrows=n, ncols=1, figsize=(12, 3.5 * n))
    if n == 1:
        axes = [axes]

    for i, (metric, label, fallback_color) in enumerate(metrics):
        ax = axes[i]
        if metric not in df.columns:
            print(f"[!] Missing column: {metric}")
            continue

        df_sorted = df.sort_values(metric, ascending=False).reset_index(drop=True)

        # compute colors for each row according to pair_key
        bar_colors = [color_map.get(k, fallback_color) for k in df_sorted["pair_key"]]

        # draw bars with per-bar color
        bars = ax.barh(df_sorted["short_name"], df_sorted[metric], color=bar_colors, height=0.55)

        # Log scale only for Bandwidth
        if "Bandwidth" in label:
            ax.set_xscale("log")
            min_val = df_sorted[metric].replace(0, float('nan')).min()
            if pd.isna(min_val):
                ax.set_xlim(left=0.1)
            else:
                ax.set_xlim(left=max(0.1, min_val * 0.5))
            ax.set_xlabel(f"{label} (log scale)", fontsize=11)
        else:
            ax.set_xlabel(label, fontsize=11)

        ax.set_ylabel("Scenario", fontsize=11)
        ax.set_title(label, fontsize=13, weight="bold")
        ax.grid(True, linestyle="--", alpha=0.5)

        # Add numeric labels
        for bar in bars:
            width = bar.get_width()
            ax.text(
                width * 1.02,
                bar.get_y() + bar.get_height() / 2,
                f"{width:.2f}",
                va="center",
                fontsize=8,
            )

    # Create a single legend for the figure (pairs) to avoid duplicates in each subplot
    from matplotlib.patches import Patch
    legend_handles = [Patch(color=color_map[k], label=pair_display[k]) for k in unique_keys]
    if legend_handles:
        # place legend to the right center of the figure
        fig.legend(handles=legend_handles, title="Pairs", loc="center right", bbox_to_anchor=(1.02, 0.5), fontsize=8)

    plt.tight_layout(pad=2.0, rect=(0, 0, 0.85, 1.0))  # leave space on right for legend
    plt.subplots_adjust(hspace=0.6)
    plt.savefig("summary_plot.png", dpi=250, bbox_inches="tight")
    print("[+] Saved summary_plot.png")


# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    os.makedirs("experiments", exist_ok=True)
    plot_pcap_summary("experiments/all_scenarios_pcap.csv")
    plot_bw_summary("experiments/all_scenarios_summary.csv")

