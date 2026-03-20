#!/usr/bin/env bash
# =============================================================================
# Dash0 ECS Observability Tutorial
# Self-paced, interactive walkthrough: instrument an ECS app and send
# traces, logs, and metrics to Dash0 via an OTel Collector sidecar.
#
# Usage:  ./scripts/tutorial.sh
# =============================================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

banner()  { echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
step()    { echo -e "\n${B}▶ STEP $1${NC}"; echo -e "${DIM}$2${NC}\n"; }
ok()      { echo -e "${G}  ✓ $1${NC}"; }
warn()    { echo -e "${Y}  ⚠ $1${NC}"; }
fail()    { echo -e "${R}  ✗ $1${NC}"; }
info()    { echo -e "${C}  ℹ $1${NC}"; }
explain() { echo -e "  $1"; }

pause_continue() {
    echo ""
    echo -e "${DIM}  Press ENTER to continue (or Ctrl+C to exit)...${NC}"
    read -r
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn
    while true; do
        if [[ "$default" == "y" ]]; then
            echo -ne "  ${prompt} [Y/n]: "
        else
            echo -ne "  ${prompt} [y/N]: "
        fi
        read -r yn
        yn="${yn:-$default}"
        yn=$(echo "$yn" | tr '[:upper:]' '[:lower:]')
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo -e "${Y}  Please answer y or n${NC}" ;;
        esac
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

# ── Load saved config from .env if it exists ─────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # Source .env but don't override vars already set in the environment
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Strip surrounding quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        # Only set if not already in environment
        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$ENV_FILE"
fi

save_env() {
    cat > "$ENV_FILE" <<ENVEOF
# Dash0 ECS Tutorial — saved configuration
# Re-run ./scripts/tutorial.sh to reuse these values
# Delete this file to start fresh
DASH0_AUTH_TOKEN=${DASH0_AUTH_TOKEN:-}
AWS_REGION=${AWS_REGION:-}
DASH0_ENDPOINT=${DASH0_ENDPOINT:-}
AWS_PROFILE=${AWS_PROFILE:-}
ENVEOF
}

# =============================================================================
banner "Dash0 ECS Observability Tutorial"
# =============================================================================
if [[ -f "$ENV_FILE" ]]; then
    info "Loaded saved config from .env (delete .env to start fresh)"
    echo ""
fi
echo -e "  Welcome! This tutorial will walk you through:"
echo ""
echo -e "    ${C}1.${NC} Deploying a Node.js app to AWS ECS Fargate"
echo -e "    ${C}2.${NC} Adding an OpenTelemetry Collector as a sidecar container"
echo -e "    ${C}3.${NC} Sending traces, logs, and metrics to Dash0"
echo -e "    ${C}4.${NC} Exploring your telemetry data in the Dash0 UI"
echo ""
echo -e "  ${DIM}Architecture:${NC}"
echo -e "  ${DIM}  app (Node.js) ──→ OTel Collector sidecar ──→ Dash0${NC}"
echo -e "  ${DIM}       port 3000        localhost:4317           gRPC${NC}"
echo ""
echo -e "  ${Y}Estimated time: ~10 minutes${NC}"
echo -e "  ${DIM}AWS costs: minimal (single Fargate task, cleaned up at the end)${NC}"

pause_continue

# =============================================================================
banner "Pre-flight Checks"
# =============================================================================
echo -e "  Let's make sure you have everything you need.\n"

PREFLIGHT_OK=true

# ── 1. AWS CLI ───────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Checking AWS CLI...${NC}"
if command -v aws &>/dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | head -1)
    ok "AWS CLI found: ${AWS_VERSION}"
else
    fail "AWS CLI not found."
    echo ""
    echo -e "  Install it from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    echo -e "  Then re-run this tutorial."
    exit 1
fi

# ── 2. Docker ────────────────────────────────────────────────────────────────
echo -e "\n  ${BOLD}Checking Docker...${NC}"
if command -v docker &>/dev/null; then
    if docker info &>/dev/null; then
        ok "Docker is running"
    else
        fail "Docker is installed but not running."
        echo -e "  Please start Docker Desktop and re-run this tutorial."
        exit 1
    fi
else
    fail "Docker not found."
    echo -e "  Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    echo -e "  Then re-run this tutorial."
    exit 1
fi

# ── 3. AWS Credentials ──────────────────────────────────────────────────────
echo -e "\n  ${BOLD}Checking AWS credentials...${NC}"

check_aws_creds() {
    aws sts get-caller-identity --output json 2>/dev/null
}

AWS_IDENTITY=""
if AWS_IDENTITY=$(check_aws_creds); then
    AWS_ACCOUNT=$(echo "$AWS_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null)
    AWS_ARN=$(echo "$AWS_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])" 2>/dev/null)
    ok "Authenticated to AWS"
    info "Account: ${AWS_ACCOUNT}"
    info "Identity: ${AWS_ARN}"
else
    warn "No active AWS credentials found."
    echo ""
    echo -e "  You need valid AWS credentials to continue. Options:"
    echo ""
    echo -e "    ${C}1.${NC} AWS SSO login    (recommended for organizations)"
    echo -e "    ${C}2.${NC} Environment vars  (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)"
    echo -e "    ${C}3.${NC} AWS profile       (~/.aws/credentials)"
    echo ""

    if ask_yes_no "Would you like to try 'aws sso login' now?"; then
        echo ""
        # Check if there are SSO profiles configured
        SSO_PROFILES=$(aws configure list-profiles 2>/dev/null | head -20)
        if [[ -n "$SSO_PROFILES" ]]; then
            echo -e "  Available profiles:"
            echo "$SSO_PROFILES" | while read -r p; do echo -e "    ${C}•${NC} $p"; done
            echo ""
            echo -ne "  Enter profile name (or press ENTER for default): "
            read -r PROFILE_CHOICE
            if [[ -n "$PROFILE_CHOICE" ]]; then
                export AWS_PROFILE="$PROFILE_CHOICE"
                info "Using profile: ${PROFILE_CHOICE}"
            fi
        fi

        echo -e "\n  Running: ${DIM}aws sso login${NC}\n"
        if aws sso login; then
            echo ""
            if AWS_IDENTITY=$(check_aws_creds); then
                AWS_ACCOUNT=$(echo "$AWS_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null)
                AWS_ARN=$(echo "$AWS_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])" 2>/dev/null)
                ok "Authenticated to AWS"
                info "Account: ${AWS_ACCOUNT}"
                info "Identity: ${AWS_ARN}"
            else
                fail "Still unable to authenticate. Please configure AWS credentials and re-run."
                exit 1
            fi
        else
            fail "SSO login failed. Please configure AWS credentials and re-run."
            exit 1
        fi
    else
        echo ""
        echo -e "  Please configure your AWS credentials and re-run this tutorial."
        echo -e "  Guide: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html"
        exit 1
    fi
fi

# ── 4. Verify python3 (needed for JSON escaping in setup) ───────────────────
echo -e "\n  ${BOLD}Checking python3...${NC}"
if command -v python3 &>/dev/null; then
    ok "python3 found"
else
    fail "python3 not found (required for config encoding)."
    echo -e "  Most systems have this pre-installed. Install Python 3 and re-run."
    exit 1
fi

ok "All pre-flight checks passed!"

pause_continue

# =============================================================================
step "1/5" "Configure your Dash0 connection"
# =============================================================================
explain "You'll need two things from your Dash0 account:"
explain "  • An ${BOLD}auth token${NC} (starts with 'auth_')"
explain "  • Your ${BOLD}region${NC} (determines the OTLP endpoint)"
echo ""

# ── Dash0 Auth Token ─────────────────────────────────────────────────────────
if [[ -n "${DASH0_AUTH_TOKEN:-}" ]]; then
    MASKED="${DASH0_AUTH_TOKEN:0:8}...${DASH0_AUTH_TOKEN: -4}"
    info "Found DASH0_AUTH_TOKEN in environment: ${MASKED}"
    if ! ask_yes_no "Use this token?" "y"; then
        unset DASH0_AUTH_TOKEN
    fi
fi

if [[ -z "${DASH0_AUTH_TOKEN:-}" ]]; then
    echo -e "  ${BOLD}Where to find your token:${NC}"
    echo -e "    1. Go to ${C}app.dash0.com${NC} → Settings → Auth Tokens"
    echo -e "    2. Copy your ingest token (starts with 'auth_')"
    echo ""
    while true; do
        echo -ne "  Enter your Dash0 auth token: "
        read -r DASH0_AUTH_TOKEN
        if [[ "$DASH0_AUTH_TOKEN" == auth_* ]]; then
            ok "Token accepted"
            break
        elif [[ -z "$DASH0_AUTH_TOKEN" ]]; then
            warn "Token cannot be empty"
        else
            warn "Token should start with 'auth_' — are you sure this is correct?"
            if ask_yes_no "Use this token anyway?" "n"; then
                break
            fi
        fi
    done
fi
export DASH0_AUTH_TOKEN

# ── AWS Region ───────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Select your AWS region${NC} (should match your Dash0 org region):"
echo ""
echo -e "    ${C}1.${NC} eu-west-1     (EU West — Ireland)"
echo -e "    ${C}2.${NC} us-west-2     (US West — Oregon)"
echo -e "    ${C}3.${NC} us-east-2     (US East — Ohio)"
echo ""

CURRENT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -n "$CURRENT_REGION" ]]; then
    info "Current AWS_REGION: ${CURRENT_REGION}"
fi

while true; do
    echo -ne "  Choose [1/2/3] or enter a region name: "
    read -r REGION_CHOICE
    case "${REGION_CHOICE}" in
        1|eu-west-1)
            AWS_REGION="eu-west-1"
            DASH0_ENDPOINT="ingress.eu-west-1.aws.dash0.com:4317"
            break ;;
        2|us-west-2)
            AWS_REGION="us-west-2"
            DASH0_ENDPOINT="ingress.us-west-2.aws.dash0.com:4317"
            break ;;
        3|us-east-2)
            AWS_REGION="us-east-2"
            DASH0_ENDPOINT="ingress.us-east-2.aws.dash0.com:4317"
            break ;;
        "")
            if [[ -n "$CURRENT_REGION" ]]; then
                AWS_REGION="$CURRENT_REGION"
                # Map known regions to endpoints
                case "$AWS_REGION" in
                    eu-west-1) DASH0_ENDPOINT="ingress.eu-west-1.aws.dash0.com:4317" ;;
                    us-west-2) DASH0_ENDPOINT="ingress.us-west-2.aws.dash0.com:4317" ;;
                    us-east-2) DASH0_ENDPOINT="ingress.us-east-2.aws.dash0.com:4317" ;;
                    *)
                        warn "Non-standard region. You may need a custom Dash0 endpoint."
                        echo -ne "  Enter your Dash0 OTLP endpoint (e.g. api.REGION.aws.dash0.com:4317): "
                        read -r DASH0_ENDPOINT
                        ;;
                esac
                break
            else
                warn "Please select a region"
            fi
            ;;
        *)
            # User typed a custom region name
            AWS_REGION="${REGION_CHOICE}"
            warn "Custom region: ${AWS_REGION}"
            echo -ne "  Enter your Dash0 OTLP endpoint (e.g. api.REGION.aws.dash0.com:4317): "
            read -r DASH0_ENDPOINT
            if [[ -n "$DASH0_ENDPOINT" ]]; then
                break
            else
                warn "Endpoint cannot be empty"
            fi
            ;;
    esac
done
export AWS_REGION
export DASH0_ENDPOINT

echo ""
ok "Configuration:"
info "Region:   ${AWS_REGION}"
info "Endpoint: ${DASH0_ENDPOINT}"
info "Account:  ${AWS_ACCOUNT}"

# Save selections for next run
save_env
info "Saved to .env (will be reused on next run)"

pause_continue

# =============================================================================
step "2/5" "Verify AWS permissions"
# =============================================================================
explain "The setup will create: ECR repo, VPC, ALB, ECS cluster, IAM role, and a Secret."
explain "Let's verify your AWS identity can reach the services we need."
echo ""

PERMS_OK=true

echo -e "  ${BOLD}Testing AWS service access...${NC}"

# Quick smoke tests — not exhaustive, but catches the most common failures
if aws ecr describe-repositories --region "${AWS_REGION}" --max-items 1 &>/dev/null; then
    ok "ECR — accessible"
else
    fail "ECR — cannot list repositories. Check your permissions."
    PERMS_OK=false
fi

if aws ecs list-clusters --region "${AWS_REGION}" --max-results 1 &>/dev/null; then
    ok "ECS — accessible"
else
    fail "ECS — cannot list clusters. Check your permissions."
    PERMS_OK=false
fi

if aws ec2 describe-availability-zones --region "${AWS_REGION}" &>/dev/null; then
    ok "EC2/VPC — accessible"
else
    fail "EC2/VPC — cannot reach EC2. Check your permissions."
    PERMS_OK=false
fi

if aws elbv2 describe-load-balancers --region "${AWS_REGION}" --page-size 1 &>/dev/null; then
    ok "ELBv2 — accessible"
else
    fail "ELBv2 — cannot list load balancers. Check your permissions."
    PERMS_OK=false
fi

if [[ "$PERMS_OK" == "false" ]]; then
    echo ""
    fail "Some AWS permission checks failed."
    explain "You need permissions for: ECR, ECS, EC2, ELBv2, IAM, Secrets Manager, CloudWatch Logs."
    explain "An AdministratorAccess or PowerUserAccess policy will work for this tutorial."
    echo ""
    if ! ask_yes_no "Continue anyway? (setup may fail)" "n"; then
        echo -e "\n  Fix your permissions and re-run. Goodbye!"
        exit 1
    fi
fi

echo ""
ok "AWS access looks good!"

pause_continue

# =============================================================================
step "3/6" "Understand the architecture"
# =============================================================================
explain "Before we deploy, let's understand what we're building and ${BOLD}why${NC}."
echo ""
echo -e "  ${BOLD}Two ways to get telemetry to Dash0:${NC}"
echo ""
echo -e "  ${C}Pattern 1: Direct Export${NC} (simplest — good for getting started)"
echo -e "    app ── OTLP gRPC ──→ Dash0"
echo -e "    ${DIM}The app's OTel SDK exports directly. Zero infrastructure.${NC}"
echo ""
echo -e "  ${C}Pattern 2: Collector Sidecar${NC} (production-grade — what we're building)"
echo -e "    app ── localhost:4317 ──→ OTel Collector ── OTLP gRPC ──→ Dash0"
echo -e "    ${DIM}A second container enriches, batches, filters, and exports.${NC}"
echo ""
explain "${BOLD}Why use a sidecar?${NC} It gives you:"
explain "  • ${G}Automatic ECS metadata${NC} — cluster ARN, task ARN, AZ, container ID"
explain "    are stamped on every span/log. With direct export, you'd have to"
explain "    hardcode these as static env vars."
explain "  • ${G}Batching${NC} — groups spans before export, reducing outbound calls"
explain "  • ${G}Filtering${NC} — drops ALB /health check noise before it leaves your VPC"
explain "  • ${G}PII redaction${NC} — hash or strip sensitive attributes at the pipeline level"
explain "  • ${G}Retry buffering${NC} — if Dash0 is briefly unreachable, the collector"
explain "    buffers and retries. With direct export, your app threads block."
echo ""
explain "${DIM}The graduation path: start with direct export to validate → add a${NC}"
explain "${DIM}sidecar when moving to production. This tutorial shows the sidecar.${NC}"

pause_continue

echo -e "  ${BOLD}How is the app instrumented?${NC}"
echo ""
explain "The demo app uses ${C}OpenTelemetry auto-instrumentation${NC} for Node.js."
explain "Auto-instrumentation injects tracing into HTTP, DB, and queue libraries"
explain "with zero code changes — just add the OTel packages and set env vars:"
echo ""
echo -e "    ${DIM}OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317${NC}"
echo -e "    ${DIM}OTEL_EXPORTER_OTLP_PROTOCOL=grpc${NC}"
echo -e "    ${DIM}OTEL_SERVICE_NAME=dash0-demo${NC}"
echo ""
explain "The app also has ${C}manual spans${NC} for business logic (validate-order,"
explain "charge-payment, etc.) — these nest inside auto-instrumented spans"
explain "automatically. You get the best of both: library-level coverage from"
explain "auto, and business context from manual spans."
echo ""
explain "The app sends to ${C}localhost:4317${NC} — it doesn't know about Dash0."
explain "The collector handles auth, enrichment, and export."

pause_continue

echo -e "  ${BOLD}Architecture we're deploying:${NC}"
echo ""
echo -e "    ${C}╭──────────────────────────────────────────────────────────────╮${NC}"
echo -e "    ${C}│${NC}  ${BOLD}ECS Fargate Task${NC}  ${DIM}(awsvpc — shared network namespace)${NC}       ${C}│${NC}"
echo -e "    ${C}│${NC}                                                              ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}┌───────────────────────┐${NC}    ${G}┌──────────────────────────┐${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}│${NC} ${BOLD}app${NC} ${DIM}(Node.js)${NC}         ${G}│${NC}    ${G}│${NC} ${BOLD}otel-collector${NC}            ${G}│${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}│${NC}                       ${G}│${NC}    ${G}│${NC}                          ${G}│${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}│${NC} Auto-instrumented    ${G}│${NC}    ${G}│${NC} resourcedetection        ${G}│${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}│${NC} + manual spans       ${G}│──→${NC} ${G}│${NC} batch, filter, retry     ${G}│${NC}──→ ${Y}${BOLD}Dash0${NC}"
echo -e "    ${C}│${NC}  ${G}│${NC} port ${C}3000${NC}            ${G}│${NC}    ${G}│${NC} port ${C}4317${NC} ${DIM}(gRPC)${NC}         ${G}│${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}  ${G}└───────────────────────┘${NC}    ${G}└──────────────────────────┘${NC}  ${C}│${NC}"
echo -e "    ${C}│${NC}       ${DIM}↑${NC}                                                      ${C}│${NC}"
echo -e "    ${C}│${NC}  ${DIM}ALB :80 → :3000${NC}                                              ${C}│${NC}"
echo -e "    ${C}╰──────────────────────────────────────────────────────────────╯${NC}"
echo ""
explain "The collector config is a YAML pipeline:"
echo ""
echo -e "    ${C}receivers${NC}          ${C}processors${NC} ${DIM}(in order)${NC}             ${C}exporters${NC}"
echo -e "    ${DIM}──────────${NC}         ${DIM}────────────────────────${NC}          ${DIM}─────────${NC}"
echo -e "    ${G}otlp${NC}          ──→  ${G}memory_limiter${NC}  ${DIM}(always first)${NC}"
echo -e "                     ──→  ${G}resourcedetection${NC}  ${DIM}(ecs, ec2)${NC}"
echo -e "                     ──→  ${G}filter/health${NC}  ${DIM}(drop ALB noise)${NC}"
echo -e "                     ──→  ${G}batch${NC}  ${DIM}(always last)${NC}       ──→  ${Y}otlp/dash0${NC}"
echo ""
explain "${DIM}Processor order matters: memory_limiter first, batch last.${NC}"

pause_continue

# =============================================================================
step "4/6" "Deploy the app to ECS Fargate"
# =============================================================================
# Check if a prior deployment is already running
ALREADY_DEPLOYED=false
if [[ -f "${SCRIPT_DIR}/.state" ]]; then
    source "${SCRIPT_DIR}/.state"
    if [[ -n "${ALB_DNS:-}" ]]; then
        # Verify the service is actually running
        if curl -sf "http://${ALB_DNS}/health" &>/dev/null; then
            ALREADY_DEPLOYED=true
            ALB_URL="http://${ALB_DNS}"
            ok "Found existing deployment at ${ALB_URL}"
            echo ""
            if ask_yes_no "Skip deploy and go straight to traffic generation?"; then
                echo ""
            else
                ALREADY_DEPLOYED=false
            fi
        else
            info "Found prior .state file but service isn't responding — will resume setup."
            echo ""
        fi
    fi
fi

if [[ "$ALREADY_DEPLOYED" == "false" ]]; then
    explain "The setup script will:"
    explain "  1. Build the app Docker image and push to ECR"
    explain "  2. Create a VPC, subnets, ALB, security groups"
    explain "  3. Store the Dash0 auth token in Secrets Manager"
    explain "  4. Create an ECS cluster with a task definition (app + collector sidecar)"
    explain "  5. Launch the Fargate service behind the ALB"
    echo ""
    if [[ -f "${SCRIPT_DIR}/.state" ]]; then
        explain "${Y}Resuming from prior run — existing resources will be reused.${NC}"
        echo ""
    fi
    explain "${DIM}This takes ~5 minutes (less if resuming). You'll see 10 steps.${NC}"
    echo ""

    if ! ask_yes_no "Ready to deploy?"; then
        echo -e "\n  No problem — re-run when you're ready. Goodbye!"
        exit 0
    fi

    echo ""
    echo -e "  ${B}Running setup...${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
    echo ""

    # Run setup.sh with current env vars
    export DASH0_AUTH_TOKEN AWS_REGION DASH0_ENDPOINT
    if ! bash "${SCRIPT_DIR}/setup.sh"; then
        echo ""
        fail "Setup failed. Check the error above."
        explain "Common causes:"
        explain "  • Insufficient IAM permissions"
        explain "  • Resource name conflicts (try teardown first: ./scripts/teardown.sh)"
        explain "  • Docker build failure (check app/Dockerfile)"
        echo ""
        explain "Fix the issue and re-run: ${BOLD}./scripts/tutorial.sh${NC}"
        explain "The script will resume where it left off."
        exit 1
    fi

    # Read the ALB DNS from the state file
    source "${SCRIPT_DIR}/.state"
    ALB_URL="http://${ALB_DNS}"

    echo ""
    ok "Deployment complete!"
    info "Your endpoint: ${ALB_URL}"
fi

pause_continue

# =============================================================================
step "5/6" "Generate telemetry and explore in Dash0"
# =============================================================================
explain "Now let's send some traffic and see what appears in Dash0."
explain "We'll try each endpoint so you can see different trace patterns."
echo ""

# Wait for service health
echo -e "  ${BOLD}Waiting for service to be healthy...${NC}"
HEALTHY=false
for i in $(seq 1 20); do
    if curl -sf "${ALB_URL}/health" &>/dev/null; then
        HEALTHY=true
        break
    fi
    echo -ne "\r  Waiting... (${i}/20)"
    sleep 5
done
echo ""

if [[ "$HEALTHY" == "false" ]]; then
    warn "Service didn't become healthy in time."
    explain "The ECS task may still be starting. Wait a minute and try:"
    explain "  curl ${ALB_URL}/health"
    explain ""
    explain "You can continue to Step 4 manually once it's up."
    pause_continue
fi

ok "Service is healthy!"
echo ""

# ── 4a. Happy path ──────────────────────────────────────────────────────────
echo -e "  ${B}── 4a. Happy Path: Order Flow ──${NC}"
echo ""
explain "The /api/order endpoint creates a multi-span trace:"
explain "  root span → validate-order → charge-payment"
explain "  Each span has attributes like order.id, payment.amount"
explain "  Structured logs are emitted with trace_id correlation."
echo ""
echo -e "  ${DIM}Running: curl ${ALB_URL}/api/order${NC}"
RESULT=$(curl -s "${ALB_URL}/api/order" 2>/dev/null || echo '{"error":"request failed"}')
echo -e "  Response: ${G}${RESULT}${NC}"
echo ""
explain "${Y}→ In Dash0:${NC} Go to ${BOLD}Services → dash0-demo${NC}, click into the trace."
explain "  You'll see a 3-span waterfall: root → validate → payment."
explain "  Click a span to see its attributes (order.id, payment.amount, etc.)."
explain "  Check ${BOLD}correlated logs${NC} in the side panel — they share the same trace_id."

pause_continue

# ── 4b. Latency spike ───────────────────────────────────────────────────────
echo -e "  ${B}── 4b. Latency Spike ──${NC}"
echo ""
explain "The /api/slow endpoint simulates a slow database query (1.5–3s)."
explain "This shows up in your P95/P99 latency metrics in Dash0."
echo ""
echo -e "  ${DIM}Running: curl ${ALB_URL}/api/slow${NC}"
RESULT=$(curl -s "${ALB_URL}/api/slow" 2>/dev/null || echo '{"error":"request failed"}')
echo -e "  Response: ${Y}${RESULT}${NC}"
echo ""
explain "${Y}→ In Dash0:${NC} Check the ${BOLD}RED metrics${NC} (Rate, Errors, Duration)."
explain "  The P95 latency will spike from this request."
explain "  The span has db.system=postgresql and the full query string."

pause_continue

# ── 4c. Error ────────────────────────────────────────────────────────────────
echo -e "  ${B}── 4c. Error Path ──${NC}"
echo ""
explain "The /api/error endpoint throws an exception."
explain "The span records the error + stack trace, and an ERROR log is emitted."
echo ""
echo -e "  ${DIM}Running: curl ${ALB_URL}/api/error${NC}"
RESULT=$(curl -s "${ALB_URL}/api/error" 2>/dev/null || echo '{"error":"request failed"}')
echo -e "  Response: ${R}${RESULT}${NC}"
echo ""
explain "${Y}→ In Dash0:${NC} The error appears in the ${BOLD}Errors${NC} panel."
explain "  Click into the trace — the span shows status=ERROR with recordException event."
explain "  The correlated ERROR log has the error message and type."

pause_continue

# ── 4d. Burst ────────────────────────────────────────────────────────────────
echo -e "  ${B}── 4d. Parallel Spans (Waterfall Demo) ──${NC}"
echo ""
explain "The /api/burst endpoint fires 10 parallel child spans."
explain "This creates a beautiful waterfall view in Dash0."
echo ""
echo -e "  ${DIM}Running: curl ${ALB_URL}/api/burst${NC}"
RESULT=$(curl -s "${ALB_URL}/api/burst" 2>/dev/null || echo '{"error":"request failed"}')
echo -e "  Response: ${G}${RESULT}${NC}"
echo ""
explain "${Y}→ In Dash0:${NC} Find this trace — you'll see 10 parallel child spans."
explain "  Each has task.index and task.type (read/write) attributes."
explain "  Task 7 always has a cache-miss event — look for the span event marker."

pause_continue

# ── 4e. Outbound HTTP ────────────────────────────────────────────────────────
echo -e "  ${B}── 4e. Outbound HTTP Call ──${NC}"
echo ""
explain "The /api/fetch endpoint makes an HTTP call to httpbin.org."
explain "Trace context is propagated — you'll see a multi-service trace."
echo ""
echo -e "  ${DIM}Running: curl ${ALB_URL}/api/fetch${NC}"
RESULT=$(curl -s "${ALB_URL}/api/fetch" 2>/dev/null || echo '{"error":"request failed"}')
echo -e "  Response: ${G}${RESULT}${NC}"
echo ""
explain "${Y}→ In Dash0:${NC} The trace shows your app calling httpbin.org."
explain "  The span has peer.service=httpbin and the HTTP status code."

pause_continue

# ── 4f. Burst traffic ────────────────────────────────────────────────────────
echo -e "  ${B}── 4f. Traffic Burst ──${NC}"
echo ""
explain "Let's fire 30 mixed requests to populate the RED metrics dashboard."
explain "This uses the fire.sh script with a weighted mix of endpoints."
echo ""

if ask_yes_no "Fire 30 requests now?"; then
    echo ""
    bash "${SCRIPT_DIR}/fire.sh" "${ALB_URL}"
    echo ""
    explain "${Y}→ In Dash0:${NC} Give it 30 seconds, then check ${BOLD}Services → dash0-demo${NC}."
    explain "  You should see:"
    explain "  • ${BOLD}Rate${NC}    — request throughput"
    explain "  • ${BOLD}Errors${NC}  — ~10% error rate (from /api/error calls)"
    explain "  • ${BOLD}Duration${NC} — P50/P95/P99 with the /api/slow latency spike"
fi

pause_continue

# ── 4g. ECS Resource Attributes ──────────────────────────────────────────────
echo -e "  ${B}── 4g. Check ECS Resource Attributes ──${NC}"
echo ""
explain "The collector's ${BOLD}resourcedetection${NC} processor automatically stamps"
explain "every span and log with ECS infrastructure metadata."
echo ""
explain "Open any trace in Dash0 and check the ${BOLD}Resource Attributes${NC}:"
echo ""
echo -e "    ${C}aws.ecs.cluster.arn${NC}      — the cluster ARN"
echo -e "    ${C}aws.ecs.task.arn${NC}          — the specific task instance"
echo -e "    ${C}aws.ecs.task.family${NC}       — dash0-demo"
echo -e "    ${C}aws.ecs.launchtype${NC}        — FARGATE"
echo -e "    ${C}cloud.region${NC}              — ${AWS_REGION}"
echo -e "    ${C}cloud.availability_zone${NC}   — the AZ the task runs in"
echo -e "    ${C}container.name${NC}            — app"
echo -e "    ${C}container.id${NC}              — the container's ID"
echo ""
explain "These are injected by the collector — the app code doesn't set them."
explain "This is the key value of the sidecar pattern: automatic infrastructure context."

pause_continue

# =============================================================================
step "6/6" "Clean up"
# =============================================================================
explain "The tutorial is complete! Let's clean up the AWS resources."
explain "This will delete: ECS service, cluster, ALB, VPC, IAM role, ECR repo, and the secret."
echo ""

if ask_yes_no "Delete all AWS resources now?"; then
    echo ""
    echo -e "  ${B}Running teardown...${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
    echo ""
    if bash "${SCRIPT_DIR}/teardown.sh"; then
        echo ""
        ok "All resources deleted!"
    else
        echo ""
        warn "Teardown had some issues. You may want to check the AWS console"
        warn "for leftover resources (VPC, security groups, etc.)."
    fi
else
    echo ""
    info "Resources left running. When you're done exploring, run:"
    echo -e "    ${BOLD}./scripts/teardown.sh${NC}"
    echo ""
    info "To send more traffic:"
    echo -e "    ${BOLD}curl ${ALB_URL}/api/order${NC}"
    echo -e "    ${BOLD}./scripts/fire.sh ${ALB_URL}${NC}"
    echo -e "    ${BOLD}./scripts/fire.sh ${ALB_URL} --continuous${NC}"
fi

# =============================================================================
banner "Tutorial Complete!"
# =============================================================================
echo -e "  ${BOLD}What you learned:${NC}"
echo ""
echo -e "    ${G}✓${NC} Direct export vs. collector sidecar — and when to use each"
echo -e "    ${G}✓${NC} Auto-instrumentation captures HTTP/DB/queue traces with zero code changes"
echo -e "    ${G}✓${NC} Manual spans add business context (order IDs, payment amounts)"
echo -e "    ${G}✓${NC} The collector sidecar enriches with ECS metadata automatically"
echo -e "    ${G}✓${NC} RED metrics, trace waterfalls, errors, and correlated logs in Dash0"
echo ""
echo -e "  ${BOLD}Key takeaways:${NC}"
echo ""
echo -e "    • The app sends OTLP to ${C}localhost:4317${NC} — it doesn't know about Dash0"
echo -e "    • The collector sidecar handles auth, enrichment, batching, and export"
echo -e "    • ${C}resourcedetection${NC} auto-stamps ECS metadata — zero app changes"
echo -e "    • Trace-log correlation works via trace_id/span_id injection"
echo -e "    • ${BOLD}Graduation path:${NC} start with direct export, add the sidecar for production"
echo ""
echo -e "  ${BOLD}Take-home reference files:${NC}"
echo ""
echo -e "    ${C}output/task-definition-template.json${NC}"
echo -e "      Reusable ECS task def with placeholders — adapt for your own services."
echo -e "      Both app + OTel Collector sidecar containers, health checks, env vars."
echo ""
echo -e "    ${C}output/task-definition-deployed.json${NC}"
echo -e "      The exact task def that was deployed (with your real ARNs/regions)."
echo ""
echo -e "    ${C}collector/otel-collector-config.yaml${NC}"
echo -e "      The collector pipeline config: resourcedetection, batch, filter, export."
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo ""
echo -e "    • Read ${C}articles/001-ecs-sidecar-vs-direct-export.md${NC} for the full"
echo -e "      architecture guide (collector images, IaC examples, troubleshooting)"
echo -e "    • Copy the template task def and adapt it for your own services"
echo -e "    • Try adding a custom processor (PII redaction, tail sampling)"
echo ""
echo -e "  ${DIM}Dash0 docs: https://dash0.com/docs${NC}"
echo ""
