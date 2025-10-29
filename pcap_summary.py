#!/usr/bin/env python3
import os
import re
import argparse
import pandas as pd
import subprocess

CLIENT_IP = "192.168.50.10"
SERVER_IP = "192.168.60.20"

# By default we do not process UDP client captures unless --include-udp is set
PROCESS_UDP_DEFAULT = False

# ============================================================
# Helper: Run tshark and return DataFrame of numeric fields
# ============================================================
def tshark_fields(pcap, fields, display_filter):
    cmd = ["tshark", "-r", pcap, "-Y", display_filter, "-Tfields"]
    for f in fields:
        cmd += ["-e", f]
    cmd += ["-E", "separator=\t"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
        lines = [l.split("\t") for l in out.stdout.strip().split("\n") if l.strip()]
        if not lines:
            return pd.DataFrame()
        df = pd.DataFrame(lines, columns=fields)
        for f in fields:
            df[f] = pd.to_numeric(df[f], errors="coerce")
        return df.dropna()
    except subprocess.CalledProcessError:
        return pd.DataFrame()

# ============================================================
# Summarize one PCAP with role-based metrics
# ============================================================
def summarize_pcap_metrics(pcap_path):
    fname = os.path.basename(pcap_path)
    fname_l = fname.lower()
    summary = {"pcap": fname}

    if not os.path.exists(pcap_path) or os.path.getsize(pcap_path) == 0:
        return None

    # Determine role and tshark filter (use lower-case name checks)
    if "client" in fname_l:
        tcp_filter = f"tcp and (ip.src=={CLIENT_IP} or ip.dst=={SERVER_IP})"
        role = "client"
    elif "server" in fname_l:
        tcp_filter = f"tcp and (ip.src=={SERVER_IP} or ip.dst=={CLIENT_IP})"
        role = "server"
    else:
        tcp_filter = "tcp"
        role = "bottleneck"

    # ==============================
    # Metrics by node type
    # ==============================

    # ---- CLIENT: sender pacing + ACK timing ----
    if role == "client":
        df_time = tshark_fields(pcap_path, ["frame.time_relative"], tcp_filter)
        if not df_time.empty and len(df_time) > 1:
            diffs = df_time["frame.time_relative"].diff().dropna() * 1000
            summary["gap_avg_ms"] = diffs.mean()
        else:
            summary["gap_avg_ms"] = 0

        ack_filter = tcp_filter + " and tcp.flags.ack==1"
        df_ack = tshark_fields(pcap_path, ["frame.time_relative"], ack_filter)
        if not df_ack.empty and len(df_ack) > 1:
            adiffs = df_ack["frame.time_relative"].diff().dropna() * 1000
            summary["ack_interval_avg_ms"] = adiffs.mean()
        else:
            summary["ack_interval_avg_ms"] = 0

        summary["rtt_avg_ms"] = 0
        summary["rtt_std_ms"] = 0
        summary["cwnd_avg_kB"] = 0

    # ---- BOTTLENECK: RTT + queue delay + cwnd proxy ----
    elif role == "bottleneck":
        df_tcp = tshark_fields(pcap_path,
                               ["tcp.analysis.ack_rtt", "tcp.analysis.bytes_in_flight"],
                               tcp_filter)
        if not df_tcp.empty:
            summary["rtt_avg_ms"] = df_tcp["tcp.analysis.ack_rtt"].mean() * 1000
            summary["rtt_std_ms"] = df_tcp["tcp.analysis.ack_rtt"].std() * 1000
            summary["cwnd_avg_kB"] = df_tcp["tcp.analysis.bytes_in_flight"].mean() / 1024
        else:
            summary["rtt_avg_ms"] = 0
            summary["rtt_std_ms"] = 0
            summary["cwnd_avg_kB"] = 0

        df_time = tshark_fields(pcap_path, ["frame.time_relative"], tcp_filter)
        if not df_time.empty and len(df_time) > 1:
            diffs = df_time["frame.time_relative"].diff().dropna() * 1000
            summary["gap_avg_ms"] = diffs.mean()
        else:
            summary["gap_avg_ms"] = 0

        ack_filter = tcp_filter + " and tcp.flags.ack==1"
        df_ack = tshark_fields(pcap_path, ["frame.time_relative"], ack_filter)
        if not df_ack.empty and len(df_ack) > 1:
            adiffs = df_ack["frame.time_relative"].diff().dropna() * 1000
            summary["ack_interval_avg_ms"] = adiffs.mean()
        else:
            summary["ack_interval_avg_ms"] = 0

    # ---- SERVER: ACK response behavior ----
    elif role == "server":
        ack_filter = tcp_filter + " and tcp.flags.ack==1"
        df_ack = tshark_fields(pcap_path, ["frame.time_relative"], ack_filter)
        if not df_ack.empty and len(df_ack) > 1:
            adiffs = df_ack["frame.time_relative"].diff().dropna() * 1000
            summary["ack_interval_avg_ms"] = adiffs.mean()
        else:
            summary["ack_interval_avg_ms"] = 0

        summary["rtt_avg_ms"] = 0
        summary["rtt_std_ms"] = 0
        summary["cwnd_avg_kB"] = 0
        summary["gap_avg_ms"] = 0

    return summary

# ============================================================
# Parse ss_client.txt to extract avg RTT and CWND
# ============================================================
def parse_ss_file(ss_path):
    if not os.path.exists(ss_path):
        return 0, 0
    rtts, cwnds = [], []
    with open(ss_path) as f:
        for line in f:
            # try to be robust: ss output may contain 'rtt:123.45/0.00' or 'rtt 123.45'
            if "rtt" in line or "cwnd" in line:
                # capture first float for rtt (before optional slash)
                m_rtt = re.search(r"rtt[:=]?\s*([0-9]+(?:\.[0-9]+)?)", line)
                m_cwnd = re.search(r"cwnd[:=]?\s*(\d+)", line)
                if m_rtt:
                    try:
                        rtts.append(float(m_rtt.group(1)))
                    except ValueError:
                        pass
                if m_cwnd:
                    try:
                        cwnds.append(int(m_cwnd.group(1)))
                    except ValueError:
                        pass
    avg_rtt = sum(rtts) / len(rtts) if rtts else 0
    avg_cwnd = sum(cwnds) / len(cwnds) / 1024 if cwnds else 0  # KB
    return avg_rtt, avg_cwnd

# ============================================================
# Normalize run folder name (e.g., run_1)
# ============================================================
def normalize_run_name(run_folder):
    match = re.search(r"run[_-]?(\d+)", run_folder)
    return f"run_{match.group(1)}" if match else run_folder

# ============================================================
# Main processing logic
# ============================================================
def process_all_runs(root="demo", include_udp=PROCESS_UDP_DEFAULT):
    all_summaries = []

    if not os.path.exists(root):
        print(f"[!] Root path does not exist: {root}")
        return

    # Detect whether `root` is an experiments directory containing scenario subfolders
    # or a scenario folder that directly contains run_*/run-* directories. If the
    # latter, treat the provided root as a single scenario so users can call:
    #   python pcap_summary.py experiments/bwNORMAL_oneflow_pfifo
    entries = sorted(os.listdir(root))
    is_run_level = any(re.search(r"run[_-]?\d+", name) and os.path.isdir(os.path.join(root, name))
                       for name in entries)

    if is_run_level:
        # root directly contains runs -> treat it as one scenario
        scenarios = [os.path.basename(root)]
        scenario_paths = [root]
    else:
        # root contains scenario folders
        scenarios = entries
        scenario_paths = [os.path.join(root, s) for s in scenarios]

    for scenario, scenario_path in zip(scenarios, scenario_paths):
        if not os.path.isdir(scenario_path):
            continue

        scenario_summaries = []
        for run in sorted(os.listdir(scenario_path)):
            run_path = os.path.join(scenario_path, run)
            if not os.path.isdir(run_path):
                continue
            run_id = normalize_run_name(run)

            ss_path = os.path.join(run_path, "ss_client.txt")
            ss_rtt, ss_cwnd = parse_ss_file(ss_path)

            # Only include the pcap files produced by oneflow_script.sh:
            # - client_tcp_*.pcap
            # - client_udp_*.pcap (optional, controlled by include_udp)
            # - server.pcap
            # - bottleneck.pcap
            candidates = []
            for f in sorted(os.listdir(run_path)):
                lf = f.lower()
                if not lf.endswith('.pcap'):
                    continue
                if lf.startswith('client_tcp'):
                    candidates.append(f)
                elif lf == 'server.pcap':
                    candidates.append(f)
                elif lf == 'bottleneck.pcap':
                    candidates.append(f)
                elif include_udp and lf.startswith('client_udp'):
                    candidates.append(f)
            pcap_files = candidates
            for pcap_name in pcap_files:
                pcap_path = os.path.join(run_path, pcap_name)
                summary = summarize_pcap_metrics(pcap_path)
                if summary:
                    summary["run"] = run_id
                    summary["scenario"] = scenario
                    summary["ss_avg_rtt_ms"] = ss_rtt
                    summary["ss_avg_cwnd"] = ss_cwnd
                    scenario_summaries.append(summary)
                    all_summaries.append(summary)


        # Write per-scenario summary (one row per pcap)
        if scenario_summaries:
            df_summary = pd.DataFrame(scenario_summaries).fillna(0)
            df_summary = df_summary[[
                "pcap", "run", "rtt_avg_ms", "rtt_std_ms", "cwnd_avg_kB",
                "gap_avg_ms", "ack_interval_avg_ms", "ss_avg_rtt_ms", "ss_avg_cwnd"
            ]]
            out_csv = os.path.join(scenario_path, "pcap_summary.csv")
            df_summary.to_csv(out_csv, index=False)
            print(f"[+] Wrote {out_csv}")

    # ============================================================
    # Global summary (average per-run, then per-scenario)
    # ============================================================
    if all_summaries:
        df_all = pd.DataFrame(all_summaries).fillna(0)

        # 1) Trung bình theo run: gom tất cả pcap trong mỗi run -> 1 dòng/run
        df_run_avg = df_all.groupby(["scenario", "run"]).agg({
            "gap_avg_ms": "mean",
            "ack_interval_avg_ms": "mean",
            "ss_avg_rtt_ms": "mean",
            "ss_avg_cwnd": "mean"
        }).reset_index()

        # (Tùy chọn) thêm thống kê số pcap mỗi run đóng góp
        df_run_count = df_all.groupby(["scenario", "run"]).agg(n_pcaps=("pcap", "count")).reset_index()
        df_run_avg = df_run_avg.merge(df_run_count, on=["scenario", "run"])

        # 2) Trung bình theo scenario trên các run (mỗi run đóng góp đều nhau)
        df_avg = df_run_avg.groupby("scenario").agg({
            "gap_avg_ms": "mean",
            "ack_interval_avg_ms": "mean",
            "ss_avg_rtt_ms": "mean",
            "ss_avg_cwnd": "mean",
            "n_pcaps": "sum"   # tổng số pcap trong scenario (thông tin bổ sung)
        }).reset_index()

        out_csv = os.path.join(root, "all_scenarios_pcap.csv")
        df_avg.to_csv(out_csv, index=False)
        print(f"[+] Wrote aggregated averages to {out_csv}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Summarize pcaps produced by oneflow_script.sh")
    parser.add_argument("root", nargs='?', default="demo", help="root experiments folder (default: demo)")
    parser.add_argument("--include-udp", action="store_true", help="also process client_udp_*.pcap files")
    args = parser.parse_args()
    print(f"[+] Scanning experiments under: {args.root}  (include_udp={args.include_udp})")
    process_all_runs(root=args.root, include_udp=args.include_udp)