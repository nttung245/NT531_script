#!/bin/bash
# Script chạy iperf3 + collectors cho 1 scenario, lưu theo cấu trúc experiments/SCENARIO_runX_timestamp
# Capture tổng trên client, server, bottleneck; tách TCP/UDP từ pcap client sau mỗi run
# Updated: client tcpdump continuous capture + post-run tách tcp/udp

# ---- CONFIG ----
USER="root"                           # đổi nếu cần
SERVER_IP="192.168.60.20"
BOTTLENECK_IP="192.168.50.1"
RUNS=3
SCENARIO="bwNORMAL_multiflow_pfifo"
OUT_BASE="experiments"
TCP_TIME=15
UDP_TIME=15
UDP_BW="0"                            # "0" = as-fast-as-possible; hoặc "100M"
TCP_FLOWS=5                           # số luồng TCP song song
UDP_FLOWS=5
CLIENT_IF="enp0s8"
SERVER_IF="enp0s8"
BOTTLENECK_IF="enp0s9"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
# ---- END CONFIG ----

set -u
mkdir -p "${OUT_BASE}"
mkdir -p "${OUT_BASE}/${SCENARIO}"

timestamp() { date +"%F %T"; }

for run in $(seq 1 "$RUNS"); do
  OUTDIR="${OUT_BASE}/${SCENARIO}/${SCENARIO}_run_${run}"
  mkdir -p "$OUTDIR"
  REMOTE_TMP="/tmp/exp_${SCENARIO}_run${run}"

  echo "$(timestamp) [MAIN] Starting run ${run}, output -> ${OUTDIR}"

  echo "$(timestamp) [BOTTLENECK] Start tcpdump & ifstat on ${BOTTLENECK_IP} (${BOTTLENECK_IF})"
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "
    set -u
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    sudo pkill tcpdump || true
  sudo nohup tcpdump -i ${BOTTLENECK_IF} -w ${REMOTE_TMP}/bottleneck.pcap >/dev/null 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/bottleneck_tcpdump.pid
    nohup ifstat -i ${BOTTLENECK_IF} -t 1 > ${REMOTE_TMP}/ifstat_bottleneck_${BOTTLENECK_IF}.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ifstat_bottleneck.pid
  " || echo "$(timestamp) [WARN] SSH to bottleneck failed"

  echo "$(timestamp) [SERVER] Start tcpdump, ifstat, iperf3 server and ss on ${SERVER_IP} (${SERVER_IF})"
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "
    set -u
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    sudo pkill tcpdump || true
  sudo nohup tcpdump -i ${SERVER_IF} -w ${REMOTE_TMP}/server.pcap >/dev/null 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/server_tcpdump.pid

    # start iperf3 server
    pkill iperf3 || true
    nohup iperf3 -s > ${REMOTE_TMP}/iperf3_server.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/iperf3_server.pid

    # start ifstat on server interface
    nohup ifstat -i ${SERVER_IF} -t 1 > ${REMOTE_TMP}/ifstat_server_${SERVER_IF}.log 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ifstat_server.pid

    # === robust ss starter ===
    SS_BIN=\$(command -v ss || true)
    if [ -z "\$SS_BIN" ]; then
      echo "[ERROR] ss not found on server" >&2
    else
      nohup bash -lc 'while true; do "\$SS_BIN" -tinm >> ${REMOTE_TMP}/ss_server.txt; sleep 1; done' > ${REMOTE_TMP}/ss_server.nohup 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/ss_server.pid
    fi
  " || echo "$(timestamp) [WARN] SSH to server failed"

  echo "$(timestamp) [CLIENT] Start local collectors (ss, ifstat) and continuous tcpdump"
  nohup bash -c "while true; do ss -tinm >> \"${OUTDIR}/ss_client.txt\"; sleep 1; done" & CLIENT_SS_PID=$!
  nohup ifstat -i ${CLIENT_IF} -t 1 > "${OUTDIR}/ifstat_client_${CLIENT_IF}.log" 2>&1 < /dev/null & CLIENT_IFSTAT_PID=$!

  # Start continuous tcpdump on client (capture all protocols) -> client_all.pcap
  # Use sudo if not running as root
  sudo pkill tcpdump || true
  nohup sudo tcpdump -i ${CLIENT_IF} -w "${OUTDIR}/client_all.pcap" >/dev/null 2>&1 < /dev/null & CLIENT_TCPDUMP_PID=$!
  sleep 1   # chờ iperf3 server sẵn sàng

  echo "$(timestamp) [TEST] Running TCP iperf3 (client -> ${SERVER_IP}) for ${TCP_TIME}s"
  iperf3 -c ${SERVER_IP} -P ${TCP_FLOWS} -t ${TCP_TIME} -J > "${OUTDIR}/tcp.json" || echo "$(timestamp) [WARN] iperf3 TCP returned non-zero"

  echo "$(timestamp) [TEST] Running UDP iperf3 (client -> ${SERVER_IP}) for ${UDP_TIME}s bw=${UDP_BW}"
  if [ "$UDP_BW" = "0" ]; then
  iperf3 -c ${SERVER_IP} -u -b 0 -P ${UDP_FLOWS} -t ${UDP_TIME} -J > "${OUTDIR}/udp.json" || echo "$(timestamp) [WARN] iperf3 UDP returned non-zero"
  else
  iperf3 -c ${SERVER_IP} -u -b ${UDP_BW} -P ${UDP_FLOWS} -t ${UDP_TIME} -J > "${OUTDIR}/udp.json" || echo "$(timestamp) [WARN] iperf3 UDP returned non-zero"
  fi

  echo "$(timestamp) [CLIENT] Stopping local collectors..."
  kill ${CLIENT_SS_PID} ${CLIENT_IFSTAT_PID} 2>/dev/null || true

  # Stop client tcpdump after tests
  echo "$(timestamp) [CLIENT] Stopping client tcpdump (continuous)"
  sudo kill ${CLIENT_TCPDUMP_PID} 2>/dev/null || true
  sleep 0.5

  echo "$(timestamp) [SERVER] Stopping remote collectors and changing ownership (if needed)..."
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "
    set -u
    [ -f ${REMOTE_TMP}/iperf3_server.pid ] && kill \$(cat ${REMOTE_TMP}/iperf3_server.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/server_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/server_tcpdump.pid) 2>/dev/null || true || true
    [ -f ${REMOTE_TMP}/ifstat_server.pid ] && kill \$(cat ${REMOTE_TMP}/ifstat_server.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/ss_server.pid ] && kill \$(cat ${REMOTE_TMP}/ss_server.pid) 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/server.pcap 2>/dev/null || true
  " || echo "$(timestamp) [WARN] SSH to server stop failed"

  echo "$(timestamp) [BOTTLENECK] Stopping remote collectors and changing ownership..."
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "
    set -u
    [ -f ${REMOTE_TMP}/bottleneck_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/bottleneck_tcpdump.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/ifstat_bottleneck.pid ] && kill \$(cat ${REMOTE_TMP}/ifstat_bottleneck.pid) 2>/dev/null || true
    sudo chown ${USER}:${USER} ${REMOTE_TMP}/bottleneck.pcap 2>/dev/null || true
  " || echo "$(timestamp) [WARN] SSH to bottleneck stop failed"

  echo "$(timestamp) [COPY] Copying pcaps and logs to ${OUTDIR}..."
  scp -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/bottleneck.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp bottleneck failed"
  scp -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/server.pcap" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp server pcap failed"
  scp -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/iperf3_server.log" "${OUTDIR}/" || echo "$(timestamp) [WARN] scp server log failed"
  scp -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/ss_server.txt" "${OUTDIR}/" || true
  scp -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/ifstat_server_${SERVER_IF}.log" "${OUTDIR}/" || true
  scp -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/ifstat_bottleneck_${BOTTLENECK_IF}.log" "${OUTDIR}/" || true

  # optional: cleanup remote tmp
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true

  # Post-processing: tách TCP / UDP từ client_all.pcap để có file riêng nếu cần
  if [ -f "${OUTDIR}/client_all.pcap" ]; then
    echo "$(timestamp) [POST] Splitting client_all.pcap -> client_tcp_5201.pcap & client_udp_5201.pcap"
    # only keep tcp/udp for port 5201
    tcpdump -r "${OUTDIR}/client_all.pcap" 'tcp and port 5201' -w "${OUTDIR}/client_tcp_5201.pcap" 2>/dev/null || true
    tcpdump -r "${OUTDIR}/client_all.pcap" 'udp and port 5201' -w "${OUTDIR}/client_udp_5201.pcap" 2>/dev/null || true
    # remove big capture to save space; keep only the port-specific pcaps
    rm -f "${OUTDIR}/client_all.pcap" 2>/dev/null || true
  else
    echo "$(timestamp) [POST] WARNING: client_all.pcap not found"
  fi

  echo "$(timestamp) [DONE] Run ${run} complete. Results in ${OUTDIR}"
  echo "-------------------------------------------------------------"
  sleep 5
done

echo "$(timestamp) All runs for ${SCENARIO} finished."