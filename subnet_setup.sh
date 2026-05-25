#!/usr/bin/env bash
# =============================================================================
# StormEdge — Subnet Setup & OS Tuning Script
#
# Auto-detects GCP primary IP + interface, configures alias subnet IPs,
# tunes the OS kernel for high-CPS TCP exhaustion, writes rc.local
# persistence, and builds the stormedge binary.
#
# Usage:
#   sudo bash subnet_setup.sh                            # full auto-detect
#   sudo IFACE=ens4 bash subnet_setup.sh                 # override interface
#   sudo ALIAS_CIDR=10.156.0.32/27 bash subnet_setup.sh  # override alias block
#   sudo PREFIX=26 bash subnet_setup.sh                  # set subnet prefix
#   sudo bash subnet_setup.sh --no-build                 # skip binary build
#   sudo bash subnet_setup.sh --no-persist               # skip rc.local write
# =============================================================================

set -euo pipefail

# ── colour helpers ─────────────────────────────────────────────────────────────
RED='\033[1;31m'
RED2='\033[0;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
WHT='\033[1;37m'
NC='\033[0m'

info()  { echo -e "${RED}[▶]${NC} $*"; }
ok()    { echo -e "${GRN}[✔]${NC} $*"; }
warn()  { echo -e "${YLW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
hdr()   { echo -e "${RED}$*${NC}"; }

# ── argument parsing ───────────────────────────────────────────────────────────
DO_BUILD=true
DO_PERSIST=true
for arg in "$@"; do
    [[ "$arg" == "--no-build"   ]] && DO_BUILD=false
    [[ "$arg" == "--no-persist" ]] && DO_PERSIST=false
done

# ── root check ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ── banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  ╔═╗┌┬┐┌─┐┬─┐┌┬┐╔═╗┌┬┐┌─┐┌─┐                          ║"
echo "  ║  ╚═╗ │ │ │├┬┘│││║╣  │││ ┬├┤                           ║"
echo "  ║  ╚═╝ ┴ └─┘┴└─┴ ┴╚═╝─┴┘└─┘└─┘${NC}${WHT}  v1.1  Subnet Setup${RED}     ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║  Alias IP config  ·  OS tuning  ·  rc.local persist     ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. detect primary IP ───────────────────────────────────────────────────────
info "Detecting primary IP..."

PRIMARY_IP=""

# Try GCP metadata server first (3s timeout)
if PRIMARY_IP=$(curl -sf --connect-timeout 3 \
        "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" \
        -H "Metadata-Flavor: Google" 2>/dev/null); then
    ok "GCP metadata primary IP: ${WHT}${PRIMARY_IP}${NC}"
else
    # AWS IMDSv2
    TOKEN=$(curl -sf --connect-timeout 2 -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
        PRIMARY_IP=$(curl -sf --connect-timeout 2 \
            "http://169.254.169.254/latest/meta-data/local-ipv4" \
            -H "X-aws-ec2-metadata-token: $TOKEN" 2>/dev/null || true)
    fi

    # Generic fallback
    if [[ -z "$PRIMARY_IP" ]]; then
        PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -n "$PRIMARY_IP" ]] || die "Cannot detect primary IP"
        warn "Cloud metadata unavailable — using hostname -I: ${PRIMARY_IP}"
    else
        ok "AWS metadata primary IP: ${WHT}${PRIMARY_IP}${NC}"
    fi
fi

if ! [[ "$PRIMARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Detected IP '${PRIMARY_IP}' is not valid IPv4"
fi

# ── 2. detect interface ────────────────────────────────────────────────────────
info "Detecting network interface..."

if [[ -n "${IFACE:-}" ]]; then
    ok "Interface override: ${WHT}${IFACE}${NC}"
else
    IFACE=$(ip addr show 2>/dev/null \
        | awk -v ip="$PRIMARY_IP" '
            /^[0-9]+: / { iface = $2; gsub(/:$/, "", iface) }
            $1 == "inet" && index($2, ip"/") { print iface; exit }
        ')
    if [[ -z "$IFACE" ]]; then
        IFACE=$(ip route get 8.8.8.8 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
    [[ -n "$IFACE" ]] || die "Cannot detect network interface"
    ok "Interface: ${WHT}${IFACE}${NC}"
fi

ip link show "$IFACE" &>/dev/null || die "Interface ${IFACE} does not exist"

# ── 3. subnet prefix selection ─────────────────────────────────────────────────
echo ""
hdr "  ╔══════════════════════════════════════════════════════════╗"
hdr "  ║              Select Subnet Prefix Size                   ║"
hdr "  ╠══════════════════════════════════════════════════════════╣"

printf "${RED}  ║${NC}  %-8s %-10s %-12s %-16s %s${RED}║${NC}\n" \
    "Prefix" "IPs" "Port pairs" "Recommended for" ""
hdr "  ╟──────────────────────────────────────────────────────────╢"

declare -A PREFIX_HOSTS=(
    [21]=2048 [22]=1024 [23]=512 [24]=256
    [25]=128  [26]=64   [27]=32  [28]=16
    [29]=8    [30]=4    [31]=2   [32]=1
)
declare -A PREFIX_LABEL=(
    [21]="128M   Bare-metal / dedicated"
    [22]="65M    Bare-metal / dedicated"
    [23]="32M    High-end VPS"
    [24]="16M    High-end VPS"
    [25]=" 8M    Mid-range VPS"
    [26]=" 4M    Mid-range VPS (recommended)"
    [27]=" 2M    Your current /27 VM ★"
    [28]=" 1M    Small VPS"
    [29]="512k   Minimal"
    [30]="256k   Minimal"
    [31]="128k   Single pair"
    [32]=" 64k   Single IP (no alias)"
)

for pfx in 21 22 23 24 25 26 27 28 29 30 31 32; do
    ips="${PREFIX_HOSTS[$pfx]}"
    label="${PREFIX_LABEL[$pfx]}"
    if [[ "$pfx" == "27" ]]; then
        printf "${RED}  ║${NC}  ${RED}%-8s${NC} ${WHT}%-10s${NC} %-28s ${RED}║${NC}\n" \
            "/$pfx" "$ips IPs" "$label"
    else
        printf "${RED}  ║${NC}  %-8s %-10s %-28s ${RED}║${NC}\n" \
            "/$pfx" "$ips IPs" "$label"
    fi
done

hdr "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# Use env var PREFIX if set, otherwise prompt
if [[ -n "${PREFIX:-}" ]]; then
    CHOSEN_PREFIX="$PREFIX"
    ok "Prefix override from env: /${CHOSEN_PREFIX}"
else
    read -rp "$(echo -e "  ${RED}▶${NC} Enter prefix length ${WHT}[27]${NC}: ")" CHOSEN_PREFIX
    CHOSEN_PREFIX="${CHOSEN_PREFIX:-27}"
fi

# Validate chosen prefix
if ! [[ "$CHOSEN_PREFIX" =~ ^[0-9]+$ ]] || \
   (( CHOSEN_PREFIX < 21 || CHOSEN_PREFIX > 32 )); then
    die "Invalid prefix /${CHOSEN_PREFIX}. Valid range: /21 – /32"
fi

ALIAS_IP_COUNT="${PREFIX_HOSTS[$CHOSEN_PREFIX]}"
ok "Selected: /${CHOSEN_PREFIX}  (${ALIAS_IP_COUNT} IPs)"

# ── 4. derive alias subnet block ──────────────────────────────────────────────
info "Deriving alias /${CHOSEN_PREFIX} subnet block..."

IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$PRIMARY_IP"

if [[ -n "${ALIAS_CIDR:-}" ]]; then
    ok "Alias CIDR override: ${WHT}${ALIAS_CIDR}${NC}"
    ALIAS_BASE=$(echo "$ALIAS_CIDR" | cut -d'/' -f1)
    IFS='.' read -r ab1 ab2 ab3 ab4 <<< "$ALIAS_BASE"
    ALIAS_OCT="${ab1}.${ab2}.${ab3}"
    BLOCK_SIZE=$(( 1 << (32 - CHOSEN_PREFIX) ))
    START_HOST=$(( ab4 ))
    END_HOST=$(( ab4 + ALIAS_IP_COUNT - 1 ))
else
    # Auto-derive: next block of the chosen prefix above the primary IP's block
    BLOCK_SIZE=$(( 1 << (32 - CHOSEN_PREFIX) ))
    PRIMARY_BLOCK=$(( (oc4 / BLOCK_SIZE) * BLOCK_SIZE ))
    NEXT_BLOCK=$(( PRIMARY_BLOCK + BLOCK_SIZE ))

    # If next block overflows, use the block before instead
    if (( NEXT_BLOCK + BLOCK_SIZE > 255 )); then
        NEXT_BLOCK=$(( PRIMARY_BLOCK - BLOCK_SIZE ))
        (( NEXT_BLOCK < 0 )) && die "Cannot derive alias /${CHOSEN_PREFIX} from ${PRIMARY_IP} — specify ALIAS_CIDR manually"
    fi

    ALIAS_OCT="${oc1}.${oc2}.${oc3}"
    START_HOST=$NEXT_BLOCK
    END_HOST=$(( NEXT_BLOCK + ALIAS_IP_COUNT - 1 ))
    ALIAS_CIDR="${ALIAS_OCT}.${NEXT_BLOCK}/${CHOSEN_PREFIX}"
fi

# Clamp end host to .254 (avoid .255 broadcast)
if (( END_HOST > 254 )); then
    END_HOST=254
    ALIAS_IP_COUNT=$(( END_HOST - START_HOST + 1 ))
    warn "End host clamped to .254 — effective alias count: ${ALIAS_IP_COUNT}"
fi

# ── 5. print configuration summary ────────────────────────────────────────────
echo ""
echo -e "${RED}  ─────────────────────────────────────────────────────────${NC}"
info "Configuration"
echo -e "    Primary IP    : ${WHT}${PRIMARY_IP}${NC}"
echo -e "    Interface     : ${WHT}${IFACE}${NC}"
echo -e "    Alias CIDR    : ${WHT}${ALIAS_CIDR}${NC}"
echo -e "    Alias range   : ${WHT}${ALIAS_OCT}.${START_HOST}${NC} — ${WHT}${ALIAS_OCT}.${END_HOST}${NC}"
echo -e "    Alias count   : ${WHT}${ALIAS_IP_COUNT}${NC}"
echo -e "    Port pairs    : ${WHT}~$(echo "scale=1; ${ALIAS_IP_COUNT} * 64000 / 1000000" | bc)M${NC}"
echo -e "${RED}  ─────────────────────────────────────────────────────────${NC}"
echo ""

# ── 6. current interface state ─────────────────────────────────────────────────
info "Current interface state:"
ip addr show "$IFACE"
echo ""

# ── 7. add alias IPs ───────────────────────────────────────────────────────────
info "Adding ${ALIAS_IP_COUNT} alias IPs to ${WHT}${IFACE}${NC}..."
ADDED=0
SKIPPED=0

for i in $(seq "$START_HOST" "$END_HOST"); do
    ALIAS="${ALIAS_OCT}.${i}"
    if ip addr add "${ALIAS}/32" dev "$IFACE" 2>/dev/null; then
        echo -e "  ${GRN}+${NC} ${ALIAS}"
        (( ADDED++ )) || true
    else
        echo -e "  ${YLW}~${NC} ${ALIAS} (already exists)"
        (( SKIPPED++ )) || true
    fi
done

ok "Added ${WHT}${ADDED}${NC} IPs, ${SKIPPED} already existed"
echo ""

# ── 8. verify ──────────────────────────────────────────────────────────────────
info "Verifying alias IPs on ${IFACE}:"
ip addr show "$IFACE" | grep "inet " | grep -v "127.0.0.1" || warn "No IPs matched"
echo ""

# ── 9. OS kernel tuning ────────────────────────────────────────────────────────
info "Applying kernel tuning for high-CPS TCP..."

# CRITICAL: allows binding to alias IPs that may not have a route yet
sysctl -w net.ipv4.ip_nonlocal_bind=1            >/dev/null
sysctl -w net.ipv4.ip_freebind=1                 >/dev/null

# Port range: full ~64k ports per source IP
sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null

# Rapid socket recycling — essential for high-CPS reconnect loops
sysctl -w net.ipv4.tcp_tw_reuse=1                >/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=3             >/dev/null
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000    >/dev/null

# SYN backlog — ensures our own bind path doesn't stall
sysctl -w net.ipv4.tcp_max_syn_backlog=65536     >/dev/null
sysctl -w net.core.somaxconn=65536               >/dev/null

# NIC queue — prevents packet drops at 80k+ CPS
sysctl -w net.core.netdev_max_backlog=500000     >/dev/null

# Socket buffers — tuned for high-throughput TCP
sysctl -w net.core.wmem_max=268435456            >/dev/null
sysctl -w net.core.rmem_max=67108864             >/dev/null
sysctl -w "net.ipv4.tcp_wmem=4096 87380 268435456" >/dev/null
sysctl -w "net.ipv4.tcp_rmem=4096 87380 67108864"  >/dev/null

# Disable slow-start after idle — keeps connections aggressive
sysctl -w net.ipv4.tcp_slow_start_after_idle=0   >/dev/null

# TCP timestamps — enables SO_BUSY_POLL compat and accurate RTT
sysctl -w net.ipv4.tcp_timestamps=1              >/dev/null

# TCP Fast Open (client+server) — reduces handshake latency on retries
sysctl -w net.ipv4.tcp_fastopen=3                >/dev/null

# Reduce RST noise from our own closed ports
sysctl -w net.ipv4.tcp_abort_on_overflow=0       >/dev/null

# Conntrack — raise limit to avoid NFCONNTRACK_FULL drops
if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    sysctl -w net.netfilter.nf_conntrack_max=2000000  >/dev/null && \
        ok "nf_conntrack_max → 2M" || warn "nf_conntrack_max not settable"
fi

ok "Kernel tuning applied"

# ── 10. file descriptor limits ─────────────────────────────────────────────────
info "Raising FD limits..."

ulimit -n 1048576 2>/dev/null && ok "Session FD limit → 1,048,576" \
    || warn "ulimit -n failed — adding to /etc/security/limits.conf"

LIMITS_CONF="/etc/security/limits.conf"
LIMITS_BLOCK="# StormEdge FD limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576"

if grep -q "StormEdge FD limits" "$LIMITS_CONF" 2>/dev/null; then
    ok "FD limits already present in ${LIMITS_CONF}"
else
    printf '\n%s\n' "$LIMITS_BLOCK" >> "$LIMITS_CONF"
    ok "Added FD limits to ${LIMITS_CONF}"
fi

# ── 11. CPU governor ───────────────────────────────────────────────────────────
info "Setting CPU governor to performance..."
if ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor &>/dev/null; then
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
    ok "CPU governor → performance"
else
    warn "CPU freq scaling unavailable (typical for VMs) — skipping"
fi

# ── 12. hugepages (optional — reduces TLB pressure at high conn counts) ────────
info "Configuring hugepages..."
HUGEPAGES=512   # 512 × 2MB = 1GB
if [[ -f /proc/sys/vm/nr_hugepages ]]; then
    echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
    ACTUAL=$(cat /proc/sys/vm/nr_hugepages)
    ok "Hugepages: ${ACTUAL} × 2MB = $(( ACTUAL * 2 ))MB reserved"
else
    warn "Hugepages not available on this kernel — skipping"
fi

# ── 13. IRQ affinity (multi-core NIC balancing) ────────────────────────────────
info "Tuning NIC IRQ affinity..."
RPS_CPUS="f"  # all 4 CPUs on a 4vCPU VM
QUEUE_COUNT=0
for rps in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
    [[ -f "$rps" ]] && echo "$RPS_CPUS" > "$rps" && (( QUEUE_COUNT++ )) || true
done
if (( QUEUE_COUNT > 0 )); then
    ok "RPS enabled on ${QUEUE_COUNT} RX queues (cpumask=${RPS_CPUS})"
else
    warn "RPS not available on ${IFACE} — skipping"
fi

# ── 14. rc.local persistence ───────────────────────────────────────────────────
if $DO_PERSIST; then
    info "Writing boot persistence to rc.local..."
    RC_LOCAL="/etc/rc.local"
    RC_MARKER="# StormEdge alias IPs"

    read -r -d '' ALIAS_BLOCK << ENDBLOCK || true
${RC_MARKER}
IFACE=${IFACE}
for i in \$(seq ${START_HOST} ${END_HOST}); do
    ip addr add ${ALIAS_OCT}.\${i}/32 dev \${IFACE} 2>/dev/null || true
done
sysctl -w net.ipv4.ip_nonlocal_bind=1              >/dev/null
sysctl -w net.ipv4.ip_freebind=1                   >/dev/null
sysctl -w net.ipv4.ip_local_port_range='1024 65535' >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1                  >/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=3               >/dev/null
sysctl -w net.core.netdev_max_backlog=500000        >/dev/null
sysctl -w net.ipv4.tcp_slow_start_after_idle=0     >/dev/null
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000      >/dev/null
ENDBLOCK

    if [[ -f "$RC_LOCAL" ]] && grep -q "$RC_MARKER" "$RC_LOCAL"; then
        warn "rc.local already has StormEdge block — skipping (edit ${RC_LOCAL} if needed)"
    else
        if [[ ! -f "$RC_LOCAL" ]]; then
            printf '#!/bin/bash\n\nexit 0\n' > "$RC_LOCAL"
        fi
        if grep -q "^exit 0" "$RC_LOCAL"; then
            sed -i "s|^exit 0|${ALIAS_BLOCK}\n\nexit 0|" "$RC_LOCAL"
        else
            printf '\n%s\n' "$ALIAS_BLOCK" >> "$RC_LOCAL"
        fi
        chmod +x "$RC_LOCAL"
        ok "rc.local updated: ${RC_LOCAL}"
    fi

    # Also try systemd-rc-local if available
    if systemctl list-unit-files rc-local.service &>/dev/null; then
        systemctl enable rc-local.service 2>/dev/null && \
            ok "rc-local.service enabled via systemd" || true
    fi
else
    warn "Skipping rc.local persistence (--no-persist)"
fi

# ── 15. build stormedge ────────────────────────────────────────────────────────
if $DO_BUILD; then
    echo ""
    info "Building stormedge..."

    SE_DIR="$(dirname "$(realpath "$0")")"
    SE_SRC="${SE_DIR}/stormedge.c"
    SE_BIN="${SE_DIR}/stormedge"

    if [[ ! -f "$SE_SRC" ]]; then
        die "stormedge.c not found at ${SE_SRC}. Place it alongside this script and re-run."
    fi

    if ! command -v gcc &>/dev/null; then
        info "gcc not found — attempting install..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y --no-install-recommends build-essential
        elif command -v yum &>/dev/null; then
            yum install -y gcc
        elif command -v dnf &>/dev/null; then
            dnf install -y gcc
        else
            die "Cannot install gcc — install it manually and re-run"
        fi
    fi

    GCC_VERSION=$(gcc --version | head -1)
    info "Compiler: ${GCC_VERSION}"

    gcc -O3 -march=native -mtune=native -funroll-loops -fno-plt \
        -std=c11 \
        -Wall -Wextra -Wno-unused-parameter \
        -o "$SE_BIN" "$SE_SRC" -lpthread \
        && ok "Built: ${WHT}${SE_BIN}${NC}" \
        || die "Build failed — check gcc output above"

    chmod +x "$SE_BIN"
    SIZE=$(du -h "$SE_BIN" | cut -f1)
    ok "Binary size: ${SIZE}"
else
    warn "Skipping build (--no-build)"
    SE_BIN="$(dirname "$(realpath "$0")")/stormedge"
fi

# ── 16. performance projection ─────────────────────────────────────────────────
echo ""
echo -e "${RED}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}  ║${NC}  ${WHT}Performance Projection${NC}  —  ${WHT}Your Hardware${NC}              ${RED}║${NC}"
echo -e "${RED}  ╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}  ║${NC}  VM: 4vCPU EPYC 2.8GHz · 16GB RAM · 1Gbps · /${CHOSEN_PREFIX}     ${RED}║${NC}"
echo -e "${RED}  ╟──────────────────────────────────────────────────────────╢${NC}"

# /27 = 32 IPs
# HTTP keep-alive, 256B payload
# 4 EPYC cores each run ~80-100k epoll events/sec at 2.8GHz
# With KA=256 amortising handshake: bottleneck is pure send/recv throughput
# Bandwidth: 4× workers × (256B × 100k events) = 102MB/s TX = ~820 Mbps
# Realistic with target ACK latency adding back-pressure: 80-130k PPS
# SYN mode: no payload, pure handshake — kernel limited; ~150-250k CPS

PAIRS_M=$(echo "scale=1; ${ALIAS_IP_COUNT} * 64000 / 1000000" | bc)

printf "${RED}  ║${NC}  %-20s : ${WHT}%-36s${RED}║${NC}\n" \
    "Subnet" "/${CHOSEN_PREFIX}  →  ${ALIAS_IP_COUNT} IPs  →  ~${PAIRS_M}M port pairs"
echo -e "${RED}  ╟──────────────────────────────────────────────────────────╢${NC}"
printf "${RED}  ║${NC}  %-20s : ${WHT}%-36s${RED}║${NC}\n" \
    "Mode" "Realistic PPS" ""
echo -e "${RED}  ╟──────────────────────────────────────────────────────────╢${NC}"

# Scale estimates with subnet size
BASE_HTTP=100  # k PPS baseline for single IP HTTP
BASE_SYN=180   # k CPS baseline for single IP SYN

# /27=32 IPs → port exhaustion resolved → scale to CPU limit
# CPU bottleneck on 4×EPYC: ~120-150k HTTP PPS
if   (( ALIAS_IP_COUNT >= 2048 )); then
    HTTP_EST="180 – 260k PPS  (port pairs: no limit)"
    SYN_EST="350 – 500k CPS  (near line-rate, NIC limited)"
elif (( ALIAS_IP_COUNT >= 256 )); then
    HTTP_EST="140 – 200k PPS  (CPU + NIC limited)"
    SYN_EST="250 – 380k CPS  (CPU limited)"
elif (( ALIAS_IP_COUNT >= 64 )); then
    HTTP_EST="120 – 160k PPS  (CPU limited, >${ALIAS_IP_COUNT}×4M pairs)"
    SYN_EST="200 – 280k CPS  (CPU limited)"
elif (( ALIAS_IP_COUNT >= 32 )); then
    HTTP_EST="90 – 130k PPS   (CPU limited, port pairs sufficient)"
    SYN_EST="150 – 220k CPS  (CPU limited)"
elif (( ALIAS_IP_COUNT >= 16 )); then
    HTTP_EST="70 – 100k PPS   (mild port pair pressure)"
    SYN_EST="100 – 150k CPS"
else
    HTTP_EST="40 – 70k PPS    (port pairs may limit)"
    SYN_EST="60 – 100k CPS"
fi

printf "${RED}  ║${NC}  %-20s : ${RED}%-36s${RED}║${NC}\n" \
    "HTTP keep-alive" "$HTTP_EST"
printf "${RED}  ║${NC}  %-20s : %-36s${RED}║${NC}\n" \
    "SYN (raw CPS)" "$SYN_EST"
printf "${RED}  ║${NC}  %-20s : %-36s${RED}║${NC}\n" \
    "vs Sphinx-1.5 (1 IP)" "40-45k PPS  (port exhausted)"

echo -e "${RED}  ╟──────────────────────────────────────────────────────────╢${NC}"
printf "${RED}  ║${NC}  %-20s : ${WHT}%-36s${RED}║${NC}\n" \
    "Bandwidth (HTTP)" "256B × 120k PPS = ~312 Mbps TX"
printf "${RED}  ║${NC}  %-20s : ${WHT}%-36s${RED}║${NC}\n" \
    "1Gbps headroom" "$(echo "scale=0; (1000 - 312)" | bc) Mbps remaining (not bottleneck)"
printf "${RED}  ║${NC}  %-20s : ${WHT}%-36s${RED}║${NC}\n" \
    "RAM usage" "~2.5GB at 4000 conns × 4 workers"
echo -e "${RED}  ╟──────────────────────────────────────────────────────────╢${NC}"
printf "${RED}  ║${NC}  ${YLW}%-56s${RED}║${NC}\n" \
    "★ Key gain: port exhaustion eliminated by subnet IPs"
printf "${RED}  ║${NC}  ${YLW}%-56s${RED}║${NC}\n" \
    "  Sphinx: 1 IP × 60k ports / 3s = 20k new conns/s max"
printf "${RED}  ║${NC}  ${YLW}%-56s${RED}║${NC}\n" \
    "  StormEdge /${CHOSEN_PREFIX}: ${ALIAS_IP_COUNT} IPs × 60k = $(echo "scale=0; ${ALIAS_IP_COUNT} * 60" | bc)k new conns/s"
echo -e "${RED}  ╚══════════════════════════════════════════════════════════╝${NC}"

# ── 17. quick-start reference ──────────────────────────────────────────────────
echo ""
echo -e "${RED}  ─────────────────────────────────────────────────────────${NC}"
info "Quick-start commands"
echo ""
echo -e "  # HTTP (default — highest PPS, randomised 256B payloads):"
echo -e "  ${WHT}sudo ${SE_BIN} -H TARGET -P 80 -s ${ALIAS_CIDR} -c 4000 -d 60${NC}"
echo ""
echo -e "  # SYN mode — maximum CPS, zero payload:"
echo -e "  ${WHT}sudo ${SE_BIN} -H TARGET -P 80 -s ${ALIAS_CIDR} -c 4000 -d 60 -m syn${NC}"
echo ""
echo -e "  # Maximum aggression (pin CPUs, large conn pool):"
echo -e "  ${WHT}sudo ${SE_BIN} -H TARGET -P 80 -s ${ALIAS_CIDR} -c 8000 -d 60 --pin${NC}"
echo ""
echo -e "  # Disable payload randomisation (fixed payload):"
echo -e "  ${WHT}sudo ${SE_BIN} -H TARGET -P 80 -s ${ALIAS_CIDR} --no-rand${NC}"
echo ""
echo -e "${RED}  ─────────────────────────────────────────────────────────${NC}"
echo ""
ok "StormEdge subnet setup complete."
echo ""
