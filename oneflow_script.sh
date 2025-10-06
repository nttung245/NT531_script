#!/bin/bash
# Script chạy iperf3 + collectors cho 1 scenario, lưu theo cấu trúc experiments/SCENARIO_runX_timestamp
# Capture tổng trên client, server, bottleneck; tách TCP/UDP từ pcap client sau mỗi run
# Updated: safer PID handling, cleanup trap

# ---- CONFIG ----
USER="root"                           # đổi nếu cần
SERVER_IP="192.168.60.20"
BOTTLENECK_IP="192.168.50.1"
RUNS=3
SCENARIO="bwNORMAL_oneflow_pfifo"
OUT_BASE="experiments"
TCP_TIME=15
UDP_TIME=15
UDP_BW="0"                            # "0" = as-fast-as-possible; hoặc "100M"
CLIENT_IF="enp0s8"
SERVER_IF="enp0s8"
BOTTLENECK_IF="enp0s9"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
# ---- END CONFIG ----

set -euo pipefail
mkdir -p "${OUT_BASE}"

timestamp() { date +"%F %T"; }

cleanup_local() {
  echo "$(timestamp) [CLEANUP] cleaning local background jobs..."
  # kill client local collectors if alive
  if [[ -n "${CLIENT_SS_PID-}" ]]; then kill "${CLIENT_SS_PID}" 2>/dev/null || true; fi
  if [[ -n "${CLIENT_IFSTAT_PID-}" ]]; then kill "${CLIENT_IFSTAT_PID}" 2>/dev/null || true; fi
  if [[ -n "${CLIENT_TCPDUMP_PID_TCP-}" ]]; then sudo kill "${CLIENT_TCPDUMP_PID_TCP}" 2>/dev/null || true; fi
  if [[ -n "${CLIENT_TCPDUMP_PID_UDP-}" ]]; then sudo kill "${CLIENT_TCPDUMP_PID_UDP}" 2>/dev/null || true; fi
}
cleanup_remote() {
  # best-effort: stop remote pids (no exit on error)
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "set -u; [ -f ${REMOTE_TMP}/iperf3_server.pid ] && kill \$(cat ${REMOTE_TMP}/iperf3_server.pid) 2>/dev/null || true; true" 2>/dev/null || true
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "set -u; [ -f ${REMOTE_TMP}/bottleneck_tcp_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/bottleneck_tcp_tcpdump.pid) 2>/dev/null || true; true" 2>/dev/null || true
}

trap 'cleanup_local; cleanup_remote; echo "$(timestamp) [EXIT] exiting";' EXIT INT TERM

for run in $(seq 1 "$RUNS"); do
  OUTDIR="${OUT_BASE}/${SCENARIO}_run${run}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUTDIR"
  REMOTE_TMP="/tmp/exp_${SCENARIO}_run${run}"

  echo "$(timestamp) [MAIN] Starting run ${run}, output -> ${OUTDIR}"

  echo "$(timestamp) [BOTTLENECK] Start tcpdump & ifstat on ${BOTTLENECK_IP} (${BOTTLENECK_IF})"
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "
    set -euo pipefail
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    command -v tcpdump >/dev/null || { echo '[ERROR] tcpdump not found' >&2; exit 0; }
    # use sh -c to capture correct PID of tcpdump
    sudo sh -c 'nohup tcpdump -i any tcp port 5201 -w ${REMOTE_TMP}/bottleneck_tcp_5201.pcap > ${REMOTE_TMP}/bottleneck_tcp_nohup.log 2>&1 & echo \$! > ${REMOTE_TMP}/bottleneck_tcp_tcpdump.pid'
    sudo sh -c 'nohup tcpdump -i any udp port 5201 -w ${REMOTE_TMP}/bottleneck_udp_5201.pcap > ${REMOTE_TMP}/bottleneck_udp_nohup.log 2>&1 & echo \$! > ${REMOTE_TMP}/bottleneck_udp_tcpdump.pid'
    command -v ifstat >/dev/null && nohup ifstat -i ${BOTTLENECK_IF} -t 1 > ${REMOTE_TMP}/ifstat_bottleneck_${BOTTLENECK_IF}.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ifstat_bottleneck.pid || true
  " || echo "$(timestamp) [WARN] SSH to bottleneck failed"

  echo "$(timestamp) [SERVER] Start tcpdump, ifstat, iperf3 server and ss on ${SERVER_IP} (${SERVER_IF})"
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "
    set -euo pipefail
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    command -v tcpdump >/dev/null || { echo '[WARN] tcpdump not found on server' >&2; }
    command -v iperf3 >/dev/null || { echo '[WARN] iperf3 not found on server' >&2; }
    # tcpdumps (capture pids reliably)
    sudo sh -c 'nohup tcpdump -i any tcp port 5201 -w ${REMOTE_TMP}/server_tcp_5201.pcap > ${REMOTE_TMP}/server_tcp_nohup.log 2>&1 & echo \$! > ${REMOTE_TMP}/server_tcp_tcpdump.pid' || true
    sudo sh -c 'nohup tcpdump -i any udp port 5201 -w ${REMOTE_TMP}/server_udp_5201.pcap > ${REMOTE_TMP}/server_udp_nohup.log 2>&1 & echo \$! > ${REMOTE_TMP}/server_udp_tcpdump.pid' || true

    # iperf3 server
    pkill iperf3 || true
    nohup iperf3 -s > ${REMOTE_TMP}/iperf3_server.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/iperf3_server.pid || true

    # ifstat
    command -v ifstat >/dev/null && nohup ifstat -i ${SERVER_IF} -t 1 > ${REMOTE_TMP}/ifstat_server_${SERVER_IF}.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ifstat_server.pid || true

    # ss loop (if available)
    SS_BIN=\$(command -v ss || true)
    if [ -n \"\$SS_BIN\" ]; then
      nohup bash -lc 'while true; do \"\$SS_BIN\" -tinm >> ${REMOTE_TMP}/ss_server.txt; sleep 1; done' > ${REMOTE_TMP}/ss_server.nohup 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ss_server.pid
    else
      echo '[WARN] ss not found on server' >&2
    fi
  " || echo "$(timestamp) [WARN] SSH to server failed"

  echo "$(timestamp) [CLIENT] Start local collectors (ss, ifstat) and continuous tcpdump (iperf-only)"
  nohup bash -c "while true; do ss -tinm >> \"${OUTDIR}/ss_client.txt\"; sleep 1; done" & CLIENT_SS_PID=$!
  nohup ifstat -i ${CLIENT_IF} -t 1 > "${OUTDIR}/ifstat_client_${CLIENT_IF}.log" 2>&1 < /dev/null & CLIENT_IFSTAT_PID=$!

  # Start tcpdump on client capturing only iperf traffic (port 5201)
  # use sudo sh -c to capture tcpdump PID reliably
  sudo sh -c "nohup tcpdump -i ${CLIENT_IF} tcp port 5201 -w \"${OUTDIR}/client_tcp_5201.pcap\" > \"${OUTDIR}/client_tcp_nohup.log\" 2>&1 < /dev/null & echo \$!" > "${OUTDIR}/client_tcp_pid.tmp"
  CLIENT_TCPDUMP_PID_TCP=$(cat "${OUTDIR}/client_tcp_pid.tmp" || true) || true
  sudo sh -c "nohup tcpdump -i ${CLIENT_IF} udp port 5201 -w \"${OUTDIR}/client_udp_5201.pcap\" > \"${OUTDIR}/client_udp_nohup.log\" 2>&1 < /dev/null & echo \$!" > "${OUTDIR}/client_udp_pid.tmp"
  CLIENT_TCPDUMP_PID_UDP=$(cat "${OUTDIR}/client_udp_pid.tmp" || true) || true

  sleep 1   # chờ iperf3 server sẵn sàng

  echo "$(timestamp) [TEST] Running TCP iperf3 (client -> ${SERVER_IP}) for ${TCP_TIME}s"
  iperf3 -c ${SERVER_IP} -t ${TCP_TIME} -J > "${OUTDIR}/tcp.json" || echo "$(timestamp) [WARN] iperf3 TCP returned non-zero"

  echo "$(timestamp) [TEST] Running UDP iperf3 (client -> ${SERVER_IP}) for ${UDP_TIME}s bw=${UDP_BW}"
  if [ "$UDP_BW" = "0" ]; then
    iperf3 -c ${SERVER_IP} -u -b 0 -t ${UDP_TIME} -J > "${OUTDIR}/udp.json" || echo "$(timestamp) [WARN] iperf3 UDP returned non-zero"
  else
    iperf3 -c ${SERVER_IP} -u -b ${UDP_BW} -t ${UDP_TIME} -J > "${OUTDIR}/udp.json" || echo "$(timestamp) [WARN] iperf3 UDP returned non-zero"
  fi

  echo "$(timestamp) [CLIENT] Stopping local collectors..."
  if [[ -n "${CLIENT_SS_PID-}" ]]; then kill "${CLIENT_SS_PID}" 2>/dev/null || true; fi
  if [[ -n "${CLIENT_IFSTAT_PID-}" ]]; then kill "${CLIENT_IFSTAT_PID}" 2>/dev/null || true; fi

  # Stop client tcpdump after tests
  echo "$(timestamp) [CLIENT] Stopping client tcpdump (iperf-only)"
  if [[ -n "${CLIENT_TCPDUMP_PID_TCP-}" ]]; then sudo kill "${CLIENT_TCPDUMP_PID_TCP}" 2>/dev/null || true; fi
  if [[ -n "${CLIENT_TCPDUMP_PID_UDP-}" ]]; then sudo kill "${CLIENT_TCPDUMP_PID_UDP}" 2>/dev/null || true; fi
  sleep 0.5

  echo "$(timestamp) [SERVER] Stopping remote collectors and changing ownership (if needed)..."
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "
    set -euo pipefail
    [ -f ${REMOTE_TMP}/iperf3_server.pid ] && kill \$(cat ${REMOTE_TMP}/iperf3_server.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/server_tcp_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/server_tcp_tcpdump.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/server_udp_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/server_udp_tcpdump.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/ifstat_server.pid ] && kill \$(cat ${REMOTE_TMP}/ifstat_server.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/ss_server.pid ] && kill \$(cat ${REMOTE_TMP}/ss_server.pid) 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/server_tcp_5201.pcap 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/server_udp_5201.pcap 2>/dev/null || true
  " || echo "$(timestamp) [WARN] SSH to server stop failed"

  echo "$(timestamp) [BOTTLENECK] Stopping remote collectors and changing ownership..."
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "
    set -euo pipefail
    [ -f ${REMOTE_TMP}/bottleneck_tcp_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/bottleneck_tcp_tcpdump.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/bottleneck_udp_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/bottleneck_udp_tcpdump.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/ifstat_bottleneck.pid ] && kill \$(cat ${REMOTE_TMP}/ifstat_bottleneck.pid) 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/bottleneck_tcp_5201.pcap 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/bottleneck_udp_5201.pcap 2>/dev/null || true
  " || echo "$(timestamp) [WARN] SSH to bottleneck stop failed"

  echo "$(timestamp) [COPY] Copying pcaps and logs to ${OUTDIR}..."
  # use same SSH options for scp
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/bottleneck_tcp_5201.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp bottleneck tcp pcap failed"
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/bottleneck_udp_5201.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp bottleneck udp pcap failed"
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/server_tcp_5201.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp server tcp pcap failed"
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/server_udp_5201.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp server udp pcap failed"
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/iperf3_server.log" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp server log failed"
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/ss_server.txt" "${OUTDIR}/" || true
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/ifstat_server_${SERVER_IF}.log" "${OUTDIR}/" || true
  scp $SSH_OPTS -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/ifstat_bottleneck_${BOTTLENECK_IF}.log" "${OUTDIR}/" || true

  # optional: cleanup remote tmp
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true

  echo "$(timestamp) [DONE] Run ${run} complete. Results in ${OUTDIR}"
  echo "-------------------------------------------------------------"
  sleep 5
done

echo "$(timestamp) All runs for ${SCENARIO} finished."
