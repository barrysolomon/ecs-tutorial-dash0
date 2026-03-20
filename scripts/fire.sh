#!/usr/bin/env bash
# =============================================================================
# Dash0 ECS Demo — Traffic Generator
# Fires a realistic mix of requests to populate Dash0 with interesting data
#
# Usage:
#   ./fire.sh http://your-alb-dns.amazonaws.com
#   ./fire.sh http://your-alb-dns.amazonaws.com --continuous   # runs forever
# =============================================================================
set -euo pipefail

BASE_URL="${1:?'Usage: ./fire.sh <BASE_URL> [--continuous]'}"
BASE_URL="${BASE_URL%/}"   # strip trailing slash
CONTINUOUS="${2:-}"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ENDPOINTS=(
    "/api/order"   # 40% — happy path
    "/api/order"
    "/api/order"
    "/api/order"
    "/api/burst"   # 20% — parallel spans (great for waterfall demo)
    "/api/burst"
    "/api/slow"    # 20% — latency spike
    "/api/slow"
    "/api/error"   # 10% — errors
    "/api/fetch"   # 10% — outbound HTTP
)

TOTAL=${#ENDPOINTS[@]}

fire_once() {
    local path="${ENDPOINTS[$((RANDOM % TOTAL))]}"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${path}")
    local color="${G}"
    [[ "${status}" =~ ^[45] ]] && color="${R}"
    echo -e "${color}  ${status}${NC}  ${path}"
}

# ── Wait for health ────────────────────────────────────────────────────────
echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Dash0 ECS Demo — Traffic Generator${NC}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
echo -e "${DIM}  Checking endpoint health...${NC}"
for i in $(seq 1 10); do
    if curl -sf "${BASE_URL}/health" &>/dev/null; then
        echo -e "${G}  ✓ Service is up${NC}"
        break
    fi
    echo -e "${DIM}  waiting... (${i}/10)${NC}"
    sleep 5
done

# ── Single burst ───────────────────────────────────────────────────────────
run_burst() {
    local n="${1:-30}"
    echo ""
    echo -e "${Y}  ▶ Firing ${n} requests...${NC}"
    for i in $(seq 1 "${n}"); do
        fire_once &
        sleep 0.1
    done
    wait
    echo -e "\n${G}  ✓ Burst complete.${NC} ${DIM}Check Dash0 → Services → dash0-demo${NC}"
}

if [[ "${CONTINUOUS}" == "--continuous" ]]; then
    echo -e "${Y}  ▶ Continuous mode${NC} ${DIM}— Ctrl+C to stop${NC}"
    while true; do
        run_burst 10
        sleep 15
    done
else
    run_burst 30
    echo ""
    echo -e "${DIM}  For continuous traffic:${NC}"
    echo -e "  ${C}./fire.sh ${BASE_URL} --continuous${NC}"
fi
