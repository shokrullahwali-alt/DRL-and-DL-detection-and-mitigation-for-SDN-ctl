#!/bin/bash
# -------------------------------------------------
# ONOS Cluster Manager Script (Start | Stop | Status)
# Multi-domain research setup (IoT / SDN / Server)
# -------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ONOS_VER="2.5.0"
ATOMIX_VER="3.1.5"
NET_NAME="sdn-net"
SUBNET="175.24.1.0/24"

A1_IP="175.24.1.2"     # atomix1
A2_IP="175.24.1.3"     # atomix2
A3_IP="175.24.1.4"     # atomix3
C1_IP="175.24.1.5"     # onos1
C2_IP="175.24.1.6"     # onos2
C3_IP="175.24.1.7"     # onos3
C1_ID="onos1"
C2_ID="onos2"
C3_ID="onos3"
CORE_APPS_SHORT="drivers,openflow,proxyarp,hostprovider,lldpprovider,fwd,gui2"
EXTRA_APPS_SHORT=${EXTRA_APPS_SHORT:-"onos-apps-cpman-app,onos-apps-nodemetrics,onos-apps-packet-stats,onos-providers-rest,onos-providers-openflow-message"}
DEFAULT_ONOS_APPS="${CORE_APPS_SHORT}"
if [[ -n "${EXTRA_APPS_SHORT}" ]]; then
  DEFAULT_ONOS_APPS="${DEFAULT_ONOS_APPS},${EXTRA_APPS_SHORT}"
fi
ONOS_APPS_COMBINED=${ONOS_APPS_COMBINED:-"${DEFAULT_ONOS_APPS}"}
ENABLE_CLI_APP_ACTIVATION=${ENABLE_CLI_APP_ACTIVATION:-false}

ATOMIX_CONTAINERS=(atomix1 atomix2 atomix3)
ONOS_CONTAINERS=(${C1_ID} ${C2_ID} ${C3_ID})

CONFIG_ROOT="${CONFIG_ROOT:-${SCRIPT_DIR}/cluster-config}"
ATOMIX_CONF_DIR="${CONFIG_ROOT}/atomix"
ONOS_CONF_DIR="${CONFIG_ROOT}/onos"

# Helper: generate cluster.json content
cluster_json() {
  local self_id="$1"
  local self_ip="$2"
cat <<EOF
{
  "name": "onos",
  "clusterSecret": "rocks",
  "node": {
    "id": "${self_id}",
    "ip": "${self_ip}",
    "port": 9876
  },
  "controller": [
    { "id": "${C1_ID}", "ip": "${C1_IP}", "port": 9876 },
    { "id": "${C2_ID}", "ip": "${C2_IP}", "port": 9876 },
    { "id": "${C3_ID}", "ip": "${C3_IP}", "port": 9876 }
  ],
  "storage": [
    { "id": "atomix-1", "ip": "${A1_IP}", "port": 5679 },
    { "id": "atomix-2", "ip": "${A2_IP}", "port": 5679 },
    { "id": "atomix-3", "ip": "${A3_IP}", "port": 5679 }
  ]
}
EOF
}

atomix_config() {
  local node_id="$1"
  local node_ip="$2"
cat <<EOF
{
  "cluster": {
    "clusterId": "onos",
    "node": {
      "id": "${node_id}",
      "address": "${node_ip}:5679"
    },
    "discovery": {
      "type": "bootstrap",
      "nodes": [
        { "id": "atomix-1", "address": "${A1_IP}:5679" },
        { "id": "atomix-2", "address": "${A2_IP}:5679" },
        { "id": "atomix-3", "address": "${A3_IP}:5679" }
      ]
    }
  },
  "managementGroup": {
    "type": "raft",
    "partitions": 1,
    "partitionSize": 3,
    "members": [ "atomix-1", "atomix-2", "atomix-3" ],
    "storage": { "level": "mapped" }
  },
  "partitionGroups": {
    "raft": {
      "type": "raft",
      "partitions": 3,
      "partitionSize": 3,
      "members": [ "atomix-1", "atomix-2", "atomix-3" ],
      "storage": { "level": "mapped" }
    }
  }
}
EOF
}

ensure_config_files() {
  mkdir -p "${ATOMIX_CONF_DIR}" "${ONOS_CONF_DIR}"

  declare -A atomix_nodes=(
    [atomix-1]="${A1_IP}"
    [atomix-2]="${A2_IP}"
    [atomix-3]="${A3_IP}"
  )
  for node in "${!atomix_nodes[@]}"; do
    local target="${ATOMIX_CONF_DIR}/${node}.conf"
    if [[ ! -f "${target}" ]]; then
      atomix_config "${node}" "${atomix_nodes[${node}]}" >"${target}"
    fi
  done

  declare -A onos_nodes=(
    [${C1_ID}]="${C1_IP}"
    [${C2_ID}]="${C2_IP}"
    [${C3_ID}]="${C3_IP}"
  )
  for node in "${!onos_nodes[@]}"; do
    local target="${ONOS_CONF_DIR}/${node}.json"
    if [[ ! -f "${target}" ]]; then
      cluster_json "${node}" "${onos_nodes[${node}]}" >"${target}"
    fi
  done
}

# Helper: wait for Karaf CLI inside a specific container
wait_for_cli() {
  local node="$1"
  echo "[*] Waiting for Karaf CLI in ${node}…"
  docker exec -i "$node" bash -lc '
    set -e
    KARAF_BIN=$(find /root/onos -type d -path "*/apache-karaf*/bin" | head -n1)
    CLIENT="$KARAF_BIN/client"
    for i in {1..30}; do
      echo "version" | "$CLIENT" -u karaf -p karaf -a 8101 >/dev/null 2>&1 && exit 0
      sleep 3
    done
    echo "Karaf CLI not ready in time" >&2
    exit 1
  '
}

# Helper: run a block of ONOS CLI commands inside a container
run_cli_block() {
  local node="$1"
  local cmds="$2"
  docker exec -i "$node" bash -lc "
    set -e
    KARAF_BIN=\$(find /root/onos -type d -path '*/apache-karaf*/bin' | head -n1)
    CLIENT=\"\$KARAF_BIN/client\"
    \"\$CLIENT\" -u karaf -p karaf -a 8101 \"$cmds\"
  "
}

cli_retry() {
  local node="$1"
  local command="$2"
  local attempts="${3:-6}"
  local delay="${4:-5}"
  local attempt=1
  while (( attempt <= attempts )); do
    if run_cli_block "$node" "$command"; then
      return 0
    fi
    if (( attempt < attempts )); then
      echo "[WARN] CLI command failed on ${node} (attempt ${attempt}/${attempts}). Retrying in ${delay}s..." >&2
      sleep "$delay"
    fi
    (( attempt++ ))
  done
  echo "[ERROR] CLI command failed on ${node} after ${attempts} attempts." >&2
  return 1
}

wait_for_cluster() {
  local node="$1"
  echo "[*] Waiting for distributed store on ${node}…"
  cli_retry "$node" "nodes" 12 5 >/dev/null
}

# Activate base apps
activate_apps() {
  local node="$1"
  echo "[*] Activating apps on ${node}…"
  local apps=(
    app activate org.onosproject.openflow-base
    app activate org.onosproject.openflow
    app activate org.onosproject.lldpprovider
    app activate org.onosproject.hostprovider
    app activate org.onosproject.proxyarp
    app activate org.onosproject.fwd
    app activate org.onosproject.gui2
    app activate org.onosproject.metrics
    app activate org.onosproject.cpman
    app activate org.onosproject.nodemetrics
    app activate org.onosproject.packet-stats
    app activate org.onosproject.openflow-message
    app activate org.onosproject.cpr
    app activate org.onosproject.onos-apps-mlb
    app activate org.onosproject.pathpainter
    app activate org.onosproject.rest
    app activate org.onosproject.reactive-routing
    
  )
  for app in "${apps[@]}"; do
    if ! cli_retry "$node" "app activate ${app}" 6 6; then
      echo "[WARN] Unable to activate ${app} on ${node} after multiple attempts. You may need to activate it manually once the cluster stabilises." >&2
    fi
  done
}

# Install cluster.json into a container (resolve $KARAF_HOME in-container)
install_cluster_json() {
  local node_name="$1"
  local node_id="$2"
  local node_ip="$3"
  echo "[*] Installing cluster.json into ${node_name}…"
  cluster_json "$node_id" "$node_ip" | docker exec -i "$node_name" bash -lc '
    set -e
    KARAF_HOME=${KARAF_HOME:-}
    if [[ -z "$KARAF_HOME" || ! -d "$KARAF_HOME/etc" ]]; then
      KARAF_HOME=$(find /root/onos -maxdepth 2 -type d -path "*/apache-karaf*" | head -n1)
    fi
    if [[ -z "$KARAF_HOME" || ! -d "$KARAF_HOME" ]]; then
      echo "Unable to resolve KARAF_HOME inside container" >&2
      exit 1
    fi
    mkdir -p "$KARAF_HOME/etc"
    TMP_FILE=$(mktemp)
    cat > "$TMP_FILE"
    install -m 644 "$TMP_FILE" "$KARAF_HOME/etc/cluster.json"
    CONFIG_DIR="/root/onos/config"
    mkdir -p "$CONFIG_DIR"
    install -m 644 "$TMP_FILE" "$CONFIG_DIR/cluster.json"
    rm -f "$TMP_FILE"
  '
}

restart_onos() {
  echo "[+] Restarting ONOS to load cluster.json…"
  docker restart onos1 onos2 onos3 >/dev/null
}


start_cluster() {
  ensure_config_files

  echo "[+] Creating Docker network (${NET_NAME})…"
  docker network create --subnet "${SUBNET}" "${NET_NAME}" >/dev/null 2>&1 || true

  echo "[+] Starting Atomix cluster…"
  docker run -d --name atomix1 --hostname atomix1 --network "${NET_NAME}" --ip "${A1_IP}" \
    -p 5679:5679 -v "${ATOMIX_CONF_DIR}/atomix-1.conf:/opt/atomix/conf/atomix.conf:ro" atomix/atomix:"${ATOMIX_VER}" >/dev/null
  docker run -d --name atomix2 --hostname atomix2 --network "${NET_NAME}" --ip "${A2_IP}" \
    -v "${ATOMIX_CONF_DIR}/atomix-2.conf:/opt/atomix/conf/atomix.conf:ro" atomix/atomix:"${ATOMIX_VER}" >/dev/null
  docker run -d --name atomix3 --hostname atomix3 --network "${NET_NAME}" --ip "${A3_IP}" \
    -v "${ATOMIX_CONF_DIR}/atomix-3.conf:/opt/atomix/conf/atomix.conf:ro" atomix/atomix:"${ATOMIX_VER}" >/dev/null

  echo "[+] Waiting 15s for Atomix to stabilise…"
  sleep 15

  echo "[+] Starting ONOS containers…"
  docker run -d --name onos1 --hostname onos1 --network "${NET_NAME}" --ip "${C1_IP}" \
    -p 8181:8181 -p 8101:8101 -e "ONOS_APPS=${ONOS_APPS_COMBINED}" onosproject/onos:"${ONOS_VER}" >/dev/null
  docker run -d --name onos2 --hostname onos2 --network "${NET_NAME}" --ip "${C2_IP}" \
    -p 8182:8181 -p 8102:8101 -e "ONOS_APPS=${ONOS_APPS_COMBINED}" onosproject/onos:"${ONOS_VER}" >/dev/null
  docker run -d --name onos3 --hostname onos3 --network "${NET_NAME}" --ip "${C3_IP}" \
    -p 8183:8181 -p 8103:8101 -e "ONOS_APPS=${ONOS_APPS_COMBINED}" onosproject/onos:"${ONOS_VER}" >/dev/null

  echo "[+] Waiting ~35s for ONOS to unpack Karaf…"
  sleep 35

  echo "[+] Installing cluster.json on each ONOS…"
  install_cluster_json onos1 "${C1_ID}" "${C1_IP}"
  install_cluster_json onos2 "${C2_ID}" "${C2_IP}"
  install_cluster_json onos3 "${C3_ID}" "${C3_IP}"

  restart_onos

  echo "[+] Waiting for Karaf shells…"
  wait_for_cli onos1
  wait_for_cli onos2
  wait_for_cli onos3

  echo "[+] Waiting for distributed store availability…"
  wait_for_cluster onos1
  wait_for_cluster onos2
  wait_for_cluster onos3

  if [[ "${ENABLE_CLI_APP_ACTIVATION}" == "true" ]]; then
    echo "[+] Activating core apps on all nodes…"
    activate_apps onos1
    activate_apps onos2
    activate_apps onos3
  else
    echo "[INFO] Skipping CLI app activation (ENABLE_CLI_APP_ACTIVATION=${ENABLE_CLI_APP_ACTIVATION}). Preloading features via ONOS_APPS=${ONOS_APPS_COMBINED}."
  fi

  echo "[+] Balancing mastership…"
  if ! cli_retry onos1 "balance-masters; masters" 3 5; then
    echo "[WARN] Mastership rebalance timed out on onos1. Cluster may still be converging." >&2
  fi
  if ! cli_retry onos2 "balance-masters; masters" 3 5; then
    echo "[WARN] Mastership rebalance timed out on onos2. Cluster may still be converging." >&2
  fi
  if ! cli_retry onos3 "balance-masters; masters" 3 5; then
    echo "[WARN] Mastership rebalance timed out on onos3. Cluster may still be converging." >&2
  fi
  

  # OPTIONAL: bias initial mastership (safe — no undefined vars)
  # You can uncomment and tweak these lines if you want s1→onos1, s2→onos2, s3→onos3 initially.
  # (ONOS still fails over automatically if a node dies.)
  # run_cli_block onos1 "role of:0000000000000001 ${C1_IP}"
  # run_cli_block onos2 "role of:0000000000000002 ${C2_IP}"
  # run_cli_block onos3 "role of:0000000000000003 ${C3_IP}"

  echo ""
  echo "✅ ONOS Cluster is up."
  echo "GUIs:"
  echo "  - http://127.0.0.1:8181/onos/ui   (onos1)"
  echo "  - http://127.0.0.1:8182/onos/ui   (onos2)"
  echo "  - http://127.0.0.1:8183/onos/ui   (onos3)"
  echo ""
  echo "CLI (password: karaf; add RSA opts if needed):"
  echo "  ssh -p 8101 karaf@127.0.0.1  -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedKeyTypes=+ssh-rsa"
  echo "  ssh -p 8102 karaf@127.0.0.1  -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedKeyTypes=+ssh-rsa"
  echo "  ssh -p 8103 karaf@127.0.0.1  -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedKeyTypes=+ssh-rsa"
  echo ""
  echo "Next:  sudo python3 multi_domain_topo.py"
}

stop_cluster() {
  echo "[+] Stopping ONOS containers…"
  docker stop "${ONOS_CONTAINERS[@]}" >/dev/null 2>&1 || true

  echo "[+] Stopping Atomix containers…"
  docker stop "${ATOMIX_CONTAINERS[@]}" >/dev/null 2>&1 || true

  echo "[+] Removing ONOS containers…"
  docker rm "${ONOS_CONTAINERS[@]}" >/dev/null 2>&1 || true

  echo "[+] Removing Atomix containers…"
  docker rm "${ATOMIX_CONTAINERS[@]}" >/dev/null 2>&1 || true

  echo "[+] Removing Docker network…"
  docker network rm "${NET_NAME}" >/dev/null 2>&1 || true

  echo "🛑 ONOS cluster stopped and cleaned up."
}

status_cluster() {
  echo "📊 ONOS Cluster Status:"
  docker ps --filter "name=onos" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo "📊 Atomix Status:"
  docker ps --filter "name=atomix" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

case "${1:-}" in
  start)  start_cluster ;;
  stop)   stop_cluster ;;
  status) status_cluster ;;
  *) echo "Usage: $0 {start|stop|status}"; exit 1 ;;
esac

