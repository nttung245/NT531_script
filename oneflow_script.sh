#!/bin/bash
# Script chạy iperf3 + tcpdump tổng cho 1 scenario
# Chỉ lưu pcap tổng (client_all.pcap, server.pcap, bottleneck.pcap)
# Không lưu file .err — mọi lỗi sẽ được log ra màn hình với timestamp
# Updated: phiên bản rút gọn theo yêu cầu

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

set -u
mkdir -p "${OUT_BASE}"

timestamp() { date +"%F %T"; }

# trap cleanup on exit to try stop any background client tcpdump
cleanup() {
  echo "$(timestamp) [CLEANUP] Stopping local background processes (if any)..."
  if [ ! -z "${CLIENT_TCPDUMP_PID:-}" ]; then
    sudo kill "${CLIENT_TCPDUMP_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for run in $(seq 1 "$RUNS"); do
  OUTDIR="${OUT_BASE}/${SCENARIO}_run${run}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUTDIR"
  REMOTE_TMP="/tmp/exp_${SCENARIO}_run${run}"

  echo "$(timestamp) [MAIN] Starting run ${run}, output -> ${OUTDIR}"

  echo "$(timestamp) [BOTTLENECK] Start tcpdump on ${BOTTLENECK_IP} (${BOTTLENECK_IF})"
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} bash -lc "
    set -u
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    sudo pkill tcpdump || true
    sudo nohup tcpdump -i any -w ${REMOTE_TMP}/bottleneck.pcap >/dev/null 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/bottleneck_tcpdump.pid
    echo \"[INFO] bottleneck tcpdump started, pid \$(cat ${REMOTE_TMP}/bottleneck_tcpdump.pid 2>/dev/null || echo 'N/A')\"
  " || echo "$(timestamp) [WARN] SSH to bottleneck failed or returned non-zero. See ssh output above."

  echo "$(timestamp) [SERVER] Start tcpdump and iperf3 server on ${SERVER_IP} (${SERVER_IF})"
  ssh $SSH_OPTS ${USER}@${SERVER_IP} bash -lc "
    set -u
    rm -rf ${REMOTE_TMP} 2>/dev/null || true
    mkdir -p ${REMOTE_TMP}
    sudo pkill tcpdump || true
    sudo nohup tcpdump -i any -w ${REMOTE_TMP}/server.pcap >/dev/null 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/server_tcpdump.pid

    # start iperf3 server in background (no logfile saved)
    pkill iperf3 || true
    nohup iperf3 -s >/dev/null 2>&1 < /dev/null & echo \$! > ${REMOTE_TMP}/iperf3_server.pid
    echo \"[INFO] server tcpdump and iperf3 started, tcpdump pid: \$(cat ${REMOTE_TMP}/server_tcpdump.pid 2>/dev/null || echo 'N/A')\"
  " || echo "$(timestamp) [WARN] SSH to server failed or returned non-zero. See ssh output above."

  echo "$(timestamp) [CLIENT] Start continuous tcpdump (local client) -> ${OUTDIR}/client_all.pcap"
  sudo pkill tcpdump || true
  # start continuous tcpdump on client (background) and record pid
  nohup sudo tcpdump -i ${CLIENT_IF} -w "${OUTDIR}/client_all.pcap" >/dev/null 2>&1 < /dev/null & CLIENT_TCPDUMP_PID=$!
  sleep 1   # đợi tcpdump ổn định

  echo "$(timestamp) [TEST] Running TCP iperf3 (client -> ${SERVER_IP}) for ${TCP_TIME}s"
  # không lưu json; iperf3 sẽ in ra màn hình (stdout/stderr)
  if ! iperf3 -c ${SERVER_IP} -t ${TCP_TIME}; then
    echo "$(timestamp) [WARN] iperf3 TCP returned non-zero (message printed above)"
  fi

  echo "$(timestamp) [TEST] Running UDP iperf3 (client -> ${SERVER_IP}) for ${UDP_TIME}s bw=${UDP_BW}"
  if [ "$UDP_BW" = "0" ]; then
    if ! iperf3 -c ${SERVER_IP} -u -b 0 -t ${UDP_TIME}; then
      echo "$(timestamp) [WARN] iperf3 UDP returned non-zero (message printed above)"
    fi
  else
    if ! iperf3 -c ${SERVER_IP} -u -b ${UDP_BW} -t ${UDP_TIME}; then
      echo "$(timestamp) [WARN] iperf3 UDP returned non-zero (message printed above)"
    fi
  fi

  echo "$(timestamp) [CLIENT] Stopping client tcpdump (continuous)"
  sudo kill ${CLIENT_TCPDUMP_PID} 2>/dev/null || true
  sleep 0.5

  echo "$(timestamp) [SERVER] Stopping remote iperf3 and tcpdump..."
  ssh $SSH_OPTS ${USER}@${SERVER_IP} bash -lc "
    set -u
    [ -f ${REMOTE_TMP}/iperf3_server.pid ] && kill \$(cat ${REMOTE_TMP}/iperf3_server.pid) 2>/dev/null || true
    [ -f ${REMOTE_TMP}/server_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/server_tcpdump.pid) 2>/dev/null || true
    echo \"[INFO] server stopped (if processes existed)\"
  " || echo "$(timestamp) [WARN] SSH to server stop failed or returned non-zero. See ssh output above."

  echo "$(timestamp) [BOTTLENECK] Stopping remote tcpdump..."
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} bash -lc "
    set -u
    [ -f ${REMOTE_TMP}/bottleneck_tcpdump.pid ] && sudo kill \$(cat ${REMOTE_TMP}/bottleneck_tcpdump.pid) 2>/dev/null || true
    echo \"[INFO] bottleneck tcpdump stopped (if existed)\"
  " || echo "$(timestamp) [WARN] SSH to bottleneck stop failed or returned non-zero. See ssh output above."

  echo "$(timestamp) [COPY] Copying pcaps to ${OUTDIR}..."
  # copy bottleneck pcap
  scp -o ConnectTimeout=8 ${USER}@${BOTTLENECK_IP}:"${REMOTE_TMP}/bottleneck.pcap" "${OUTDIR}/" && \
    echo "$(timestamp) [OK] Copied bottleneck.pcap" || echo "$(timestamp) [WARN] scp bottleneck.pcap failed or file missing (see scp output above)"

  # copy server pcap
  scp -o ConnectTimeout=8 ${USER}@${SERVER_IP}:"${REMOTE_TMP}/server.pcap" "${OUTDIR}/" && \
    echo "$(timestamp) [OK] Copied server.pcap" || echo "$(timestamp) [WARN] scp server.pcap failed or file missing (see scp output above)"

  # client pcap already in OUTDIR as client_all.pcap
  if [ -f "${OUTDIR}/client_all.pcap" ]; then
    echo "$(timestamp) [OK] client_all.pcap present"
  else
    echo "$(timestamp) [WARN] client_all.pcap not found in ${OUTDIR}"
  fi

  # optional: cleanup remote tmp
  ssh $SSH_OPTS ${USER}@${SERVER_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true
  ssh $SSH_OPTS ${USER}@${BOTTLENECK_IP} "rm -rf ${REMOTE_TMP}" 2>/dev/null || true

  # no post-processing splitting (user requested only keep total pcap)
  echo "$(timestamp) [DONE] Run ${run} complete. Results in ${OUTDIR}"
  echo "-------------------------------------------------------------"
  sleep 5
done

echo "$(timestamp) All runs for ${SCENARIO} finished."

