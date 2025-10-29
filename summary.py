#!/usr/bin/env python3
import os
import re
import json
import pandas as pd

ROOT_DIR = "demo"

def get_flow_count(scenario_name: str):
    m = re.search(r"_(\d+)_", scenario_name)
    if m:
        return int(m.group(1))
    return 1

def parse_iperf_json(path):
    """Parse iperf3 JSON (TCP or UDP)."""
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"[!] Error reading {path}: {e}")
        return {}

    if "error" in data:
        return {}

    proto = data.get("start", {}).get("test_start", {}).get("protocol", "").upper()
    end = data.get("end", {})

    if proto == "TCP":
        per_flow_bw, per_flow_retrans = [], []
        if "streams" in end:
            for s in end["streams"]:
                recv = s.get("receiver", {})
                send = s.get("sender", {})
                if "bits_per_second" in recv:
                    per_flow_bw.append(recv["bits_per_second"] / 1e6)
                    per_flow_retrans.append(send.get("retransmits", 0))
        elif "sum_received" in end:
            recv = end["sum_received"]
            send = end.get("sum_sent", {})
            per_flow_bw = [recv.get("bits_per_second", 0) / 1e6]
            per_flow_retrans = [send.get("retransmits", 0)]
        return {
            "protocol": proto,
            "per_flow_Mbps": per_flow_bw,
            "retrans": sum(per_flow_retrans) / len(per_flow_retrans) if per_flow_retrans else 0,
        }

    if proto == "UDP":
        per_flow_bw, per_flow_loss, per_flow_jitter = [], [], []
        if "streams" in end:
            for s in end["streams"]:
                udp = s.get("udp", {})
                if "bits_per_second" in udp:
                    per_flow_bw.append(udp["bits_per_second"] / 1e6)
                    per_flow_loss.append(udp.get("lost_percent", 0))
                    per_flow_jitter.append(udp.get("jitter_ms", 0))
        elif "sum" in end:
            s = end["sum"]
            per_flow_bw = [s.get("bits_per_second", 0) / 1e6]
            per_flow_loss = [s.get("lost_percent", 0)]
            per_flow_jitter = [s.get("jitter_ms", 0)]
        return {
            "protocol": proto,
            "per_flow_Mbps": per_flow_bw,
            "lost_pct": sum(per_flow_loss) / len(per_flow_loss) if per_flow_loss else 0,
            "jitter_ms": sum(per_flow_jitter) / len(per_flow_jitter) if per_flow_jitter else 0,
        }

    return {}

def parse_ifstat_kB(path):
    """Parse ifstat average KB/s -> return (rx, tx)."""
    if not os.path.exists(path):
        return 0, 0
    rx, tx = [], []
    with open(path) as f:
        for line in f:
            if re.match(r"^\s*\d", line):
                parts = line.split()
                if len(parts) >= 3:
                    try:
                        rx.append(float(parts[1]))
                        tx.append(float(parts[2]))
                    except ValueError:
                        pass
    if not rx:
        return 0, 0
    return sum(rx) / len(rx), sum(tx) / len(tx)

def jain_fairness(values):
    if not values or sum(values) == 0:
        return 0
    s = sum(values)
    return (s ** 2) / (len(values) * sum(v ** 2 for v in values))

def summarize_run(run_dir, flow_count):
    out = {"run_id": os.path.basename(run_dir)}
    tcp_path = os.path.join(run_dir, "tcp.json")
    udp_path = os.path.join(run_dir, "udp.json")

    tcp_flows, udp_flows = [], []
    tcp_retrans, udp_loss, udp_jitter = [], [], []

    # --- TCP ---
    if os.path.exists(tcp_path):
        data = parse_iperf_json(tcp_path)
        if data and data["protocol"] == "TCP":
            tcp_flows.extend(data["per_flow_Mbps"])
            tcp_retrans.append(data.get("retrans", 0))
    else:
        print(f"[!] Missing tcp.json in {run_dir}")

    # --- UDP ---
    if os.path.exists(udp_path):
        data = parse_iperf_json(udp_path)
        if data and data["protocol"] == "UDP":
            udp_flows.extend(data["per_flow_Mbps"])
            udp_loss.append(data.get("lost_pct", 0))
            udp_jitter.append(data.get("jitter_ms", 0))
    else:
        print(f"[!] Missing udp.json in {run_dir}")

    # --- Aggregates ---
    if tcp_flows:
        out["tcp_avg_bw_Mbps"] = sum(tcp_flows) / len(tcp_flows)
        out["tcp_fairness"] = jain_fairness(tcp_flows)
        out["tcp_avg_retrans"] = sum(tcp_retrans) / len(tcp_retrans)
    if udp_flows:
        out["udp_avg_bw_Mbps"] = sum(udp_flows) / len(udp_flows)
        out["udp_avg_lost_pct"] = sum(udp_loss) / len(udp_loss)
        out["udp_avg_jitter_ms"] = sum(udp_jitter) / len(udp_jitter)

    # --- ifstat ---
    roles = ["client", "bottleneck", "server"]
    for role in roles:
        pattern = f"ifstat_{role}_"
        file_match = [f for f in os.listdir(run_dir) if f.startswith(pattern) and f.endswith(".log")]
        if not file_match:
            continue
        path = os.path.join(run_dir, file_match[0])
        _, tx_kBps = parse_ifstat_kB(path)
        mbps = tx_kBps * 8 / 1000  # KB/s -> Mbps
        out[f"{role}_bw"] = mbps

    return out

def summarize_scenario(path, flow_count):
    runs = sorted([
        os.path.join(path, d) for d in os.listdir(path)
        if os.path.isdir(os.path.join(path, d)) and "_run_" in d
    ])

    rows = []
    for r in runs:
        print(f"[*] Processing {r}")
        rows.append(summarize_run(r, flow_count))

    if not rows:
        print(f"[!] No runs found in {path}")
        return None

    df = pd.DataFrame(rows)
    avg = df.select_dtypes("number").mean()
    avg_row = {"run_id": "avg"} | avg.to_dict()
    df = pd.concat([df, pd.DataFrame([avg_row])], ignore_index=True)

    out_path = os.path.join(path, "summary.csv")
    df.to_csv(out_path, index=False)
    print(f"[*] Saved {out_path}")

    return os.path.basename(path), avg

def main():
    scenario_summaries = []
    for scen in sorted(os.listdir(ROOT_DIR)):
        scen_path = os.path.join(ROOT_DIR, scen)
        if not os.path.isdir(scen_path):
            continue
        flow_count = get_flow_count(scen)
        print(f"\n=== Scenario: {scen} ===")
        result = summarize_scenario(scen_path, flow_count)
        if result:
            scen_name, avg_metrics = result
            avg_metrics["scenario"] = scen_name
            scenario_summaries.append(avg_metrics)

    if scenario_summaries:
        df = pd.DataFrame(scenario_summaries)
        df = df.set_index("scenario")
        out_path = os.path.join(ROOT_DIR, "all_scenarios_summary.csv")
        df.to_csv(out_path)
        print(f"\n[*] Global summary saved to {out_path}")
    else:
        print("[!] No scenarios summarized.")

if __name__ == "__main__":
    main()

