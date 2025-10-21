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
    Convert scenario names into readable short names.
    Examples:
      bw3_1_cubic_fq          -> bw3 1 cubic
      bw3_10_impairments_bbr_fq -> bw3 10 imp bbr
      bwNormal_2_bbr_fq       -> norm 2 bbr
    """
    name = name.replace("bwNormal_", "norm ").replace("bw3_", "bw3 ")
    name = name.replace("_impairments", " imp").replace("_fq", "")
    name = name.replace("_", " ")
    name = re.sub(r"\s+", " ", name).strip()
    return name

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

    # adapt columns based on your global file
    metrics = ["gap_avg_ms", "ack_interval_avg_ms", "ss_avg_rtt_ms", "ss_avg_cwnd"]
    labels = [
        "Gap avg (ms)",
        "ACK interval avg (ms)",
        "ss Avg RTT (ms)",
        "ss Avg CWND"
    ]

    fig, axes = plt.subplots(len(metrics), 1, figsize=(12, 8))
    for i, (metric, label) in enumerate(zip(metrics, labels)):
        ax = axes[i]
        if metric not in df.columns:
            print(f"[!] Missing column: {metric}")
            continue
        df_sorted = df.sort_values(metric, ascending=False)
        ax.barh(df_sorted["short_name"], df_sorted[metric], color="steelblue")
        ax.set_xlabel(label, fontsize=11)
        ax.set_ylabel("Scenario", fontsize=11)
        ax.set_title(f"{label} by Scenario", fontsize=13, weight="bold")
        ax.grid(True, linestyle="--", alpha=0.5)
    plt.tight_layout()
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
    fig, axes = plt.subplots(nrows=n, ncols=1, figsize=(12, 2.6 * n))
    if n == 1:
        axes = [axes]

    for i, (metric, label, color) in enumerate(metrics):
        ax = axes[i]
        if metric not in df.columns:
            print(f"[!] Missing column: {metric}")
            continue

        df_sorted = df.sort_values(metric, ascending=False)
        bars = ax.barh(df_sorted["short_name"], df_sorted[metric], color=color)

        # Log scale only for Bandwidth
        if "Bandwidth" in label:
            ax.set_xscale("log")
            ax.set_xlim(left=max(0.1, df_sorted[metric].min() * 0.5))
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

    plt.tight_layout()
    plt.savefig("summary_plot.png", dpi=250, bbox_inches="tight")
    print("[+] Saved summary_plot.png")

# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    os.makedirs("experiments", exist_ok=True)
    plot_pcap_summary("experiments/all_scenarios_pcap.csv")
    plot_bw_summary("experiments/all_scenarios_summary.csv")

