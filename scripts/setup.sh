#!/usr/bin/env bash
# =============================================================================
# Dash0 ECS Demo — Infrastructure Setup (resumable)
# Creates: VPC, subnets, ALB, ECS cluster, task definition, service
# Result:  A public ALB endpoint you can curl to trigger traces/logs in Dash0
#
# Resumable: each step checks if the resource already exists. If a prior run
# failed partway through, re-running picks up where it left off.
#
# Usage:
#   export DASH0_AUTH_TOKEN=auth_xxxxxxxxxxxxxxxxxxxx
#   export AWS_REGION=eu-west-1          # or us-east-1, us-west-2
#   export DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317
#   ./setup.sh
# =============================================================================
set -euo pipefail

# ── Load .env if present (command-line env vars take precedence) ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "${key}" || "${key}" =~ ^# ]] && continue
        # Only set if not already in environment (CLI overrides .env)
        if [[ -z "${!key+x}" ]]; then
            export "${key}=${value}"
        fi
    done < "${ENV_FILE}"
fi

# ── Config (override via env) ─────────────────────────────────────────────────
REGION="${AWS_REGION:-eu-west-1}"
DASH0_ENDPOINT="${DASH0_ENDPOINT:-ingress.eu-west-1.aws.dash0.com:4317}"
DASH0_AUTH_TOKEN="${DASH0_AUTH_TOKEN:?'Set DASH0_AUTH_TOKEN=auth_xxxx'}"
SERVICE_NAME="dash0-demo"
CLUSTER_NAME="dash0-demo-cluster"
PREFIX="dash0demo"
IMAGE_TAG="latest"
ENABLE_AWS_SERVICES="${ENABLE_AWS_SERVICES:-false}"
DYNAMO_TABLE="${PREFIX}-orders"

# ── Colours & helpers ─────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step() { echo -e "\n${B}▶ $1${NC}"; }
ok()   { echo -e "${G}  ✓ $1${NC}"; }
skip() { echo -e "${C}  ● $1 ${DIM}(already exists)${NC}"; }
info() { echo -e "${DIM}  $1${NC}"; }

STATE_FILE="${SCRIPT_DIR}/.state"

# ── Load prior state if resuming ──────────────────────────────────────────────
if [[ -f "${STATE_FILE}" ]]; then
    source "${STATE_FILE}"
    info "Resuming from prior run (loaded .state)"
fi

# Helper: save current state after each step
save_state() {
    cat > "${STATE_FILE}" <<STATEOF
VPC_ID=${VPC_ID:-}
SUBNET1=${SUBNET1:-}
SUBNET2=${SUBNET2:-}
ALB_ARN=${ALB_ARN:-}
ALB_DNS=${ALB_DNS:-}
TG_ARN=${TG_ARN:-}
APP_SG=${APP_SG:-}
ALB_SG=${ALB_SG:-}
IGW_ID=${IGW_ID:-}
RT_ID=${RT_ID:-}
SECRET_ARN=${SECRET_ARN:-}
EXEC_ROLE_NAME=${EXEC_ROLE_NAME:-}
CLUSTER_NAME=${CLUSTER_NAME:-}
SERVICE_NAME=${SERVICE_NAME:-}
REGION=${REGION:-}
ECR_REPO=${ECR_REPO:-}
LOG_GROUP=${LOG_GROUP:-}
ENABLE_AWS_SERVICES=${ENABLE_AWS_SERVICES:-}
DYNAMO_TABLE=${DYNAMO_TABLE:-}
S3_BUCKET=${S3_BUCKET:-}
TASK_ROLE_NAME=${TASK_ROLE_NAME:-}
STATEOF
}

# ── Derive account id ─────────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${SERVICE_NAME}"
S3_BUCKET="${PREFIX}-data-${ACCOUNT_ID}-${REGION}"

# ─────────────────────────────────────────────────────────────────────────────
step "1/10  Creating ECR repository"
# ─────────────────────────────────────────────────────────────────────────────
if aws ecr describe-repositories --repository-names "${SERVICE_NAME}" \
    --region "${REGION}" &>/dev/null; then
    skip "ECR repo: ${ECR_REPO}"
else
    aws ecr create-repository \
        --repository-name "${SERVICE_NAME}" \
        --region "${REGION}" \
        --query 'repository.repositoryUri' --output text
    ok "ECR repo: ${ECR_REPO}"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "2/10  Building & pushing Docker image"
# ─────────────────────────────────────────────────────────────────────────────
cd "${SCRIPT_DIR}/../app"
aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "${SERVICE_NAME}:${IMAGE_TAG}" .
docker tag "${SERVICE_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:${IMAGE_TAG}"
ok "Image pushed: ${ECR_REPO}:${IMAGE_TAG}"

# ─────────────────────────────────────────────────────────────────────────────
step "3/10  Creating VPC & networking"
# ─────────────────────────────────────────────────────────────────────────────
# Look up by tag if not in .state
if [[ -z "${VPC_ID:-}" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters \
        "Name=tag:Name,Values=${PREFIX}-vpc" "Name=tag:Project,Values=dash0-demo" \
        --region "${REGION}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
    [[ "${VPC_ID}" == "None" ]] && VPC_ID=""
fi

if [[ -n "${VPC_ID:-}" ]] && aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
    --region "${REGION}" &>/dev/null; then
    skip "VPC: ${VPC_ID}"
else
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 10.0.0.0/16 \
        --region "${REGION}" \
        --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
    aws ec2 create-tags --resources "${VPC_ID}" \
        --tags Key=Name,Value="${PREFIX}-vpc" Key=Project,Value=dash0-demo
    ok "VPC: ${VPC_ID}"
fi
save_state

# Internet gateway
# Look up by tag if not in .state
if [[ -z "${IGW_ID:-}" ]]; then
    IGW_ID=$(aws ec2 describe-internet-gateways --filters \
        "Name=tag:Name,Values=${PREFIX}-igw" \
        --region "${REGION}" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)
    [[ "${IGW_ID}" == "None" ]] && IGW_ID=""
fi

if [[ -n "${IGW_ID:-}" ]] && aws ec2 describe-internet-gateways \
    --internet-gateway-ids "${IGW_ID}" --region "${REGION}" &>/dev/null; then
    skip "Internet gateway: ${IGW_ID}"
else
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "${REGION}" \
        --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
    aws ec2 create-tags --resources "${IGW_ID}" \
        --tags Key=Name,Value="${PREFIX}-igw"
    ok "Internet gateway: ${IGW_ID}"
fi
save_state

# Two public subnets in different AZs (ALB requires 2+)
AZ1="${REGION}a"; AZ2="${REGION}b"
# Look up by tag if not in .state
if [[ -z "${SUBNET1:-}" ]]; then
    FOUND_SUBNETS=$(aws ec2 describe-subnets --filters \
        "Name=tag:Name,Values=${PREFIX}-public" "Name=tag:Project,Values=dash0-demo" \
        "Name=vpc-id,Values=${VPC_ID}" \
        --region "${REGION}" --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)
    if [[ -n "${FOUND_SUBNETS}" && "${FOUND_SUBNETS}" != "None" ]]; then
        SUBNET1=$(echo "${FOUND_SUBNETS}" | awk '{print $1}')
        SUBNET2=$(echo "${FOUND_SUBNETS}" | awk '{print $2}')
    fi
fi

if [[ -n "${SUBNET1:-}" ]] && aws ec2 describe-subnets --subnet-ids "${SUBNET1}" \
    --region "${REGION}" &>/dev/null; then
    skip "Subnets: ${SUBNET1}, ${SUBNET2}"
else
    SUBNET1=$(aws ec2 create-subnet \
        --vpc-id "${VPC_ID}" --cidr-block 10.0.1.0/24 \
        --availability-zone "${AZ1}" \
        --query 'Subnet.SubnetId' --output text)
    SUBNET2=$(aws ec2 create-subnet \
        --vpc-id "${VPC_ID}" --cidr-block 10.0.2.0/24 \
        --availability-zone "${AZ2}" \
        --query 'Subnet.SubnetId' --output text)
    for SN in "${SUBNET1}" "${SUBNET2}"; do
        aws ec2 modify-subnet-attribute --subnet-id "${SN}" --map-public-ip-on-launch
        aws ec2 create-tags --resources "${SN}" \
            --tags Key=Name,Value="${PREFIX}-public" Key=Project,Value=dash0-demo
    done
    ok "Subnets: ${SUBNET1}, ${SUBNET2}"
fi
save_state

# Route table
# Look up by tag if not in .state
if [[ -z "${RT_ID:-}" ]]; then
    RT_ID=$(aws ec2 describe-route-tables --filters \
        "Name=tag:Name,Values=${PREFIX}-rt" \
        "Name=vpc-id,Values=${VPC_ID}" \
        --region "${REGION}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)
    [[ "${RT_ID}" == "None" ]] && RT_ID=""
fi

if [[ -n "${RT_ID:-}" ]] && aws ec2 describe-route-tables --route-table-ids "${RT_ID}" \
    --region "${REGION}" &>/dev/null; then
    skip "Route table: ${RT_ID}"
else
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id "${VPC_ID}" --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "${RT_ID}" \
        --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}"
    aws ec2 associate-route-table --route-table-id "${RT_ID}" --subnet-id "${SUBNET1}"
    aws ec2 associate-route-table --route-table-id "${RT_ID}" --subnet-id "${SUBNET2}"
    aws ec2 create-tags --resources "${RT_ID}" \
        --tags Key=Name,Value="${PREFIX}-rt"
    ok "Route table wired up"
fi
save_state

# ─────────────────────────────────────────────────────────────────────────────
step "4/10  Creating security groups"
# ─────────────────────────────────────────────────────────────────────────────
# Look up by name if not in .state
if [[ -z "${ALB_SG:-}" ]]; then
    ALB_SG=$(aws ec2 describe-security-groups --filters \
        "Name=group-name,Values=${PREFIX}-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
        --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [[ "${ALB_SG}" == "None" ]] && ALB_SG=""
fi
if [[ -z "${APP_SG:-}" ]]; then
    APP_SG=$(aws ec2 describe-security-groups --filters \
        "Name=group-name,Values=${PREFIX}-app-sg" "Name=vpc-id,Values=${VPC_ID}" \
        --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [[ "${APP_SG}" == "None" ]] && APP_SG=""
fi

if [[ -n "${ALB_SG:-}" ]] && [[ -n "${APP_SG:-}" ]]; then
    skip "Security groups: ALB=${ALB_SG}, App=${APP_SG}"
else
    ALB_SG=$(aws ec2 create-security-group \
        --group-name "${PREFIX}-alb-sg" \
        --description "ALB public traffic" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress \
        --group-id "${ALB_SG}" --protocol tcp --port 80 --cidr 0.0.0.0/0
    aws ec2 create-tags --resources "${ALB_SG}" \
        --tags Key=Name,Value="${PREFIX}-alb-sg"

    APP_SG=$(aws ec2 create-security-group \
        --group-name "${PREFIX}-app-sg" \
        --description "ECS task traffic from ALB" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress \
        --group-id "${APP_SG}" --protocol tcp --port 3000 --source-group "${ALB_SG}"
    aws ec2 create-tags --resources "${APP_SG}" \
        --tags Key=Name,Value="${PREFIX}-app-sg"
    ok "Security groups: ALB=${ALB_SG}, App=${APP_SG}"
fi
save_state

# ─────────────────────────────────────────────────────────────────────────────
step "5/10  Creating Application Load Balancer"
# ─────────────────────────────────────────────────────────────────────────────
# Look up by ARN (from .state) or by name (if prior run created it but didn't save state)
if [[ -z "${ALB_ARN:-}" ]]; then
    ALB_ARN=$(aws elbv2 describe-load-balancers --names "${PREFIX}-alb" \
        --region "${REGION}" --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null || true)
    [[ "${ALB_ARN}" == "None" ]] && ALB_ARN=""
fi

# Verify ALB is in the correct VPC — if not, delete the stale one
if [[ -n "${ALB_ARN:-}" ]]; then
    ALB_VPC=$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
        --region "${REGION}" --query 'LoadBalancers[0].VpcId' --output text 2>/dev/null || true)
    if [[ "${ALB_VPC}" != "${VPC_ID}" ]]; then
        info "ALB is in wrong VPC (${ALB_VPC} != ${VPC_ID}) — deleting stale ALB..."
        # Delete listeners first
        for LISTENER_ARN in $(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
            --region "${REGION}" --query 'Listeners[*].ListenerArn' --output text 2>/dev/null); do
            aws elbv2 delete-listener --listener-arn "${LISTENER_ARN}" --region "${REGION}" 2>/dev/null || true
        done
        aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" --region "${REGION}" 2>/dev/null || true
        ALB_ARN=""
        ALB_DNS=""
    fi
fi

if [[ -n "${ALB_ARN:-}" ]] && aws elbv2 describe-load-balancers \
    --load-balancer-arns "${ALB_ARN}" --region "${REGION}" &>/dev/null; then
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "${ALB_ARN}" \
        --query 'LoadBalancers[0].DNSName' --output text)
    skip "ALB DNS: http://${ALB_DNS}"
else
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "${PREFIX}-alb" \
        --subnets "${SUBNET1}" "${SUBNET2}" \
        --security-groups "${ALB_SG}" \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    info "Waiting for ALB to be active..."
    aws elbv2 wait load-balancer-available --load-balancer-arns "${ALB_ARN}"

    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "${ALB_ARN}" \
        --query 'LoadBalancers[0].DNSName' --output text)
    ok "ALB DNS: http://${ALB_DNS}"
fi
save_state

# Target group — look up by name if ARN not in .state
if [[ -z "${TG_ARN:-}" ]]; then
    TG_ARN=$(aws elbv2 describe-target-groups --names "${PREFIX}-tg" \
        --region "${REGION}" --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || true)
    [[ "${TG_ARN}" == "None" ]] && TG_ARN=""
fi

# Verify TG is in the correct VPC — if not, delete the stale one
if [[ -n "${TG_ARN:-}" ]]; then
    TG_VPC=$(aws elbv2 describe-target-groups --target-group-arns "${TG_ARN}" \
        --region "${REGION}" --query 'TargetGroups[0].VpcId' --output text 2>/dev/null || true)
    if [[ "${TG_VPC}" != "${VPC_ID}" ]]; then
        info "Target group is in wrong VPC — deleting stale TG..."
        aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" --region "${REGION}" 2>/dev/null || true
        TG_ARN=""
    fi
fi

if [[ -n "${TG_ARN:-}" ]] && aws elbv2 describe-target-groups \
    --target-group-arns "${TG_ARN}" --region "${REGION}" &>/dev/null; then
    skip "Target group exists"
else
    TG_ARN=$(aws elbv2 create-target-group \
        --name "${PREFIX}-tg" \
        --protocol HTTP --port 3000 \
        --vpc-id "${VPC_ID}" \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 15 \
        --healthy-threshold-count 2 \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

    aws elbv2 create-listener \
        --load-balancer-arn "${ALB_ARN}" \
        --protocol HTTP --port 80 \
        --default-actions Type=forward,TargetGroupArn="${TG_ARN}" \
        --query 'Listeners[0].ListenerArn' --output text
    ok "Target group + listener created"
fi
save_state

# ─────────────────────────────────────────────────────────────────────────────
step "6/10  Storing Dash0 auth token in Secrets Manager"
# ─────────────────────────────────────────────────────────────────────────────
SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "dash0/auth-token" \
    --region "${REGION}" \
    --query 'ARN' --output text 2>/dev/null || true)

if [[ -z "${SECRET_ARN}" || "${SECRET_ARN}" == "None" ]]; then
    SECRET_ARN=$(aws secretsmanager create-secret \
        --name "dash0/auth-token" \
        --description "Dash0 ingest auth token" \
        --secret-string "${DASH0_AUTH_TOKEN}" \
        --region "${REGION}" \
        --query 'ARN' --output text)
    ok "Secret created: ${SECRET_ARN}"
else
    aws secretsmanager put-secret-value \
        --secret-id "dash0/auth-token" \
        --secret-string "${DASH0_AUTH_TOKEN}" \
        --region "${REGION}" &>/dev/null
    ok "Secret updated: ${SECRET_ARN}"
fi
save_state

# ─────────────────────────────────────────────────────────────────────────────
step "7/10  Creating IAM roles"
# ─────────────────────────────────────────────────────────────────────────────
# Execution role (ECS pulls image, reads secrets)
EXEC_ROLE_NAME="${PREFIX}-execution-role"
EXEC_ROLE_ARN=$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" \
    --query 'Role.Arn' --output text 2>/dev/null || true)
if [[ -z "${EXEC_ROLE_ARN}" || "${EXEC_ROLE_ARN}" == "None" ]]; then
    EXEC_ROLE_ARN=$(aws iam create-role \
        --role-name "${EXEC_ROLE_NAME}" \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{
            "Effect":"Allow",
            "Principal":{"Service":"ecs-tasks.amazonaws.com"},
            "Action":"sts:AssumeRole"
          }]
        }' --query 'Role.Arn' --output text)
    aws iam attach-role-policy \
        --role-name "${EXEC_ROLE_NAME}" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    # Allow reading the Dash0 secret
    aws iam put-role-policy \
        --role-name "${EXEC_ROLE_NAME}" \
        --policy-name "dash0-secret-access" \
        --policy-document "{
          \"Version\":\"2012-10-17\",
          \"Statement\":[{
            \"Effect\":\"Allow\",
            \"Action\":[\"secretsmanager:GetSecretValue\"],
            \"Resource\":\"${SECRET_ARN}\"
          }]
        }"
    ok "Execution role created: ${EXEC_ROLE_ARN}"
else
    skip "Execution role: ${EXEC_ROLE_ARN}"
fi
save_state

# ─────────────────────────────────────────────────────────────────────────────
step "7b/10  Creating AWS service resources (DynamoDB, S3, task role)"
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${ENABLE_AWS_SERVICES}" == "true" ]]; then
    # ── DynamoDB table ──
    if aws dynamodb describe-table --table-name "${DYNAMO_TABLE}" \
        --region "${REGION}" &>/dev/null; then
        skip "DynamoDB table: ${DYNAMO_TABLE}"
    else
        aws dynamodb create-table \
            --table-name "${DYNAMO_TABLE}" \
            --attribute-definitions AttributeName=orderId,AttributeType=S \
            --key-schema AttributeName=orderId,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "${REGION}" \
            --query 'TableDescription.TableName' --output text
        aws dynamodb wait table-exists --table-name "${DYNAMO_TABLE}" --region "${REGION}"
        ok "DynamoDB table: ${DYNAMO_TABLE}"
    fi

    # ── S3 bucket ──
    if aws s3api head-bucket --bucket "${S3_BUCKET}" --region "${REGION}" 2>/dev/null; then
        skip "S3 bucket: ${S3_BUCKET}"
    else
        if [[ "${REGION}" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${REGION}"
        else
            aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${REGION}" \
                --create-bucket-configuration LocationConstraint="${REGION}"
        fi
        ok "S3 bucket: ${S3_BUCKET}"
    fi

    # ── Task role (for app container to call DynamoDB/S3) ──
    TASK_ROLE_NAME="${PREFIX}-task-role"
    TASK_ROLE_ARN=$(aws iam get-role --role-name "${TASK_ROLE_NAME}" \
        --query 'Role.Arn' --output text 2>/dev/null || true)
    if [[ -z "${TASK_ROLE_ARN}" || "${TASK_ROLE_ARN}" == "None" ]]; then
        TASK_ROLE_ARN=$(aws iam create-role \
            --role-name "${TASK_ROLE_NAME}" \
            --assume-role-policy-document '{
              "Version":"2012-10-17",
              "Statement":[{
                "Effect":"Allow",
                "Principal":{"Service":"ecs-tasks.amazonaws.com"},
                "Action":"sts:AssumeRole"
              }]
            }' --query 'Role.Arn' --output text)
        aws iam put-role-policy \
            --role-name "${TASK_ROLE_NAME}" \
            --policy-name "dash0-demo-aws-services" \
            --policy-document "{
              \"Version\":\"2012-10-17\",
              \"Statement\":[
                {
                  \"Effect\":\"Allow\",
                  \"Action\":[
                    \"dynamodb:PutItem\",
                    \"dynamodb:GetItem\",
                    \"dynamodb:Scan\",
                    \"dynamodb:Query\"
                  ],
                  \"Resource\":\"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMO_TABLE}\"
                },
                {
                  \"Effect\":\"Allow\",
                  \"Action\":[
                    \"s3:PutObject\",
                    \"s3:GetObject\",
                    \"s3:ListBucket\"
                  ],
                  \"Resource\":[
                    \"arn:aws:s3:::${S3_BUCKET}\",
                    \"arn:aws:s3:::${S3_BUCKET}/*\"
                  ]
                }
              ]
            }"
        ok "Task role: ${TASK_ROLE_ARN}"
    else
        skip "Task role: ${TASK_ROLE_ARN}"
    fi
    save_state
else
    info "AWS services disabled (set ENABLE_AWS_SERVICES=true to create DynamoDB/S3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "8/10  Creating ECS cluster"
# ─────────────────────────────────────────────────────────────────────────────
EXISTING_CLUSTER=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" \
    --region "${REGION}" --query 'clusters[?status==`ACTIVE`].clusterName' \
    --output text 2>/dev/null || true)
if [[ "${EXISTING_CLUSTER}" == "${CLUSTER_NAME}" ]]; then
    skip "Cluster: ${CLUSTER_NAME}"
else
    aws ecs create-cluster \
        --cluster-name "${CLUSTER_NAME}" \
        --capacity-providers FARGATE \
        --region "${REGION}" \
        --query 'cluster.clusterName' --output text
    ok "Cluster: ${CLUSTER_NAME}"
fi

# CloudWatch log group for container logs
LOG_GROUP="/ecs/${SERVICE_NAME}"
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" 2>/dev/null || true
save_state

# ── OTel Collector config (passed as env var) ────────────────────────────────
# The collector receives from the app on localhost:4317, enriches with ECS
# metadata via resourcedetection, batches, filters health checks, and exports
# to Dash0. Auth token is injected via Secrets Manager env var.
OTEL_COLLECTOR_CONFIG=$(cat <<'COLLCFG'
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  resourcedetection:
    detectors: [env, ecs, ec2]
    timeout: 5s
    override: false
  batch:
    send_batch_size: 512
    timeout: 5s
    send_batch_max_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 150
    spike_limit_mib: 50
  filter/health:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["url.path"] == "/health"'
exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
  debug:
    verbosity: basic
service:
  extensions: [health_check, zpages]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, filter/health, batch]
      exporters: [otlp/dash0, debug]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp/dash0, debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp/dash0]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888
COLLCFG
)

# ─────────────────────────────────────────────────────────────────────────────
step "9/10  Registering task definition (app + collector sidecar)"
# ─────────────────────────────────────────────────────────────────────────────

# Update the Dash0 auth token
aws secretsmanager put-secret-value \
    --secret-id "dash0/auth-token" \
    --secret-string "${DASH0_AUTH_TOKEN}" \
    --region "${REGION}" &>/dev/null

# Build task definition JSON via python3 to safely embed the collector YAML.
# All values passed via env vars — no heredoc expansion to mangle quotes/newlines.
TASK_DEF_FILE=$(mktemp)
trap "rm -f ${TASK_DEF_FILE}" EXIT

_SERVICE_NAME="${SERVICE_NAME}" \
_ECR_REPO="${ECR_REPO}" \
_IMAGE_TAG="${IMAGE_TAG}" \
_EXEC_ROLE_ARN="${EXEC_ROLE_ARN}" \
_LOG_GROUP="${LOG_GROUP}" \
_REGION="${REGION}" \
_DASH0_ENDPOINT="${DASH0_ENDPOINT}" \
_SECRET_ARN="${SECRET_ARN}" \
_OTEL_COLLECTOR_CONFIG="${OTEL_COLLECTOR_CONFIG}" \
_APP_HEALTH_CMD="node -e \"require('http').get('http://localhost:3000/health',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))\"" \
_TASK_DEF_FILE="${TASK_DEF_FILE}" \
_SCRIPT_DIR="${SCRIPT_DIR}" \
_ENABLE_AWS_SERVICES="${ENABLE_AWS_SERVICES}" \
_DYNAMO_TABLE="${DYNAMO_TABLE}" \
_S3_BUCKET="${S3_BUCKET}" \
_TASK_ROLE_ARN="${TASK_ROLE_ARN:-}" \
python3 -c '
import json, os

aws_enabled = os.environ.get("_ENABLE_AWS_SERVICES", "false") == "true"
task_role_arn = os.environ.get("_TASK_ROLE_ARN", "")

app_env = [
    {"name": "PORT",                          "value": "3000"},
    {"name": "OTEL_SERVICE_NAME",             "value": os.environ["_SERVICE_NAME"]},
    {"name": "DEPLOYMENT_ENV",                "value": "demo"},
    {"name": "OTEL_EXPORTER_OTLP_ENDPOINT",  "value": "http://localhost:4317"},
    {"name": "OTEL_EXPORTER_OTLP_PROTOCOL",  "value": "grpc"},
    {"name": "OTEL_RESOURCE_ATTRIBUTES",      "value": "deployment.environment=demo"},
    {"name": "OTEL_TRACES_EXPORTER",          "value": "otlp"},
    {"name": "OTEL_LOGS_EXPORTER",            "value": "otlp"},
    {"name": "OTEL_PROPAGATORS",              "value": "tracecontext,baggage"},
    {"name": "ENABLE_AWS_SERVICES",           "value": str(aws_enabled).lower()},
    {"name": "AWS_REGION",                    "value": os.environ["_REGION"]},
    {"name": "DYNAMO_TABLE",                  "value": os.environ["_DYNAMO_TABLE"]},
    {"name": "S3_BUCKET",                     "value": os.environ["_S3_BUCKET"]},
]

task_def = {
    "family": os.environ["_SERVICE_NAME"],
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "1024",
    "memory": "2048",
    "executionRoleArn": os.environ["_EXEC_ROLE_ARN"],
    "containerDefinitions": [
        {
            "name": "app",
            "image": os.environ["_ECR_REPO"] + ":" + os.environ["_IMAGE_TAG"],
            "essential": True,
            "dependsOn": [
                {"containerName": "otel-collector", "condition": "START"}
            ],
            "portMappings": [
                {"containerPort": 3000, "protocol": "tcp"}
            ],
            "environment": app_env,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group":         os.environ["_LOG_GROUP"],
                    "awslogs-region":        os.environ["_REGION"],
                    "awslogs-stream-prefix": "app"
                }
            },
            "healthCheck": {
                "command": ["CMD-SHELL", os.environ["_APP_HEALTH_CMD"]],
                "interval": 15,
                "timeout": 5,
                "retries": 3,
                "startPeriod": 30
            }
        },
        {
            "name": "otel-collector",
            "image": "otel/opentelemetry-collector-contrib:0.120.0",
            "essential": True,
            "command": ["--config=env:OTEL_COLLECTOR_CONFIG"],
            "portMappings": [
                {"containerPort": 4317,  "protocol": "tcp"},
                {"containerPort": 4318,  "protocol": "tcp"},
                {"containerPort": 13133, "protocol": "tcp"},
                {"containerPort": 55679, "protocol": "tcp"},
                {"containerPort": 8888,  "protocol": "tcp"}
            ],
            "environment": [
                {"name": "OTEL_COLLECTOR_CONFIG", "value": os.environ["_OTEL_COLLECTOR_CONFIG"]},
                {"name": "DASH0_OTLP_ENDPOINT",  "value": os.environ["_DASH0_ENDPOINT"]}
            ],
            "secrets": [
                {
                    "name": "DASH0_AUTH_TOKEN",
                    "valueFrom": os.environ["_SECRET_ARN"]
                }
            ],
            "cpu": 256,
            "memory": 512,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group":         os.environ["_LOG_GROUP"],
                    "awslogs-region":        os.environ["_REGION"],
                    "awslogs-stream-prefix": "collector"
                }
            },
        }
    ]
}

if aws_enabled and task_role_arn:
    task_def["taskRoleArn"] = task_role_arn

with open(os.environ["_TASK_DEF_FILE"], "w") as f:
    json.dump(task_def, f, indent=2)

# ── Write reference copies to output/ ────────────────────────────────────────
import copy, re, pathlib

out_dir = pathlib.Path(os.environ["_SCRIPT_DIR"]) / ".." / "output"
out_dir.mkdir(exist_ok=True)

# 1. Actual task definition (as deployed)
with open(out_dir / "task-definition-deployed.json", "w") as f:
    json.dump(task_def, f, indent=2)
    f.write("\n")

# 2. Reusable template — replace account-specific values with placeholders
template = copy.deepcopy(task_def)
template["executionRoleArn"] = "arn:aws:iam::<ACCOUNT_ID>:role/<EXECUTION_ROLE_NAME>"
for c in template["containerDefinitions"]:
    if c["name"] == "app":
        c["image"] = "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<SERVICE_NAME>:latest"
    if "logConfiguration" in c:
        c["logConfiguration"]["options"]["awslogs-group"] = "/ecs/<SERVICE_NAME>"
        c["logConfiguration"]["options"]["awslogs-region"] = "<REGION>"
    if "secrets" in c:
        for s in c["secrets"]:
            s["valueFrom"] = "arn:aws:secretsmanager:<REGION>:<ACCOUNT_ID>:secret:<SECRET_NAME>"
    if "environment" in c:
        for e in c["environment"]:
            if e["name"] == "OTEL_COLLECTOR_CONFIG":
                e["value"] = "<SEE collector/otel-collector-config.yaml>"
            if e["name"] == "DASH0_OTLP_ENDPOINT":
                e["value"] = "api.<REGION>.aws.dash0.com:4317"
            if e["name"] == "OTEL_SERVICE_NAME":
                e["value"] = "<YOUR_SERVICE_NAME>"
            if e["name"] == "ENABLE_AWS_SERVICES":
                e["value"] = "<true|false>"
            if e["name"] == "AWS_REGION":
                e["value"] = "<REGION>"
            if e["name"] == "DYNAMO_TABLE":
                e["value"] = "<DYNAMO_TABLE_NAME>"
            if e["name"] == "S3_BUCKET":
                e["value"] = "dash0demo-data-<ACCOUNT_ID>-<REGION>"
if "taskRoleArn" in template:
    template["taskRoleArn"] = "arn:aws:iam::<ACCOUNT_ID>:role/<TASK_ROLE_NAME>"

with open(out_dir / "task-definition-template.json", "w") as f:
    json.dump(template, f, indent=2)
    f.write("\n")
'

TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json "file://${TASK_DEF_FILE}" \
    --region "${REGION}" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Task definition: ${TASK_DEF_ARN}"
info "  app       → exports to localhost:4317 (collector sidecar)"
info "  collector → enriches with ECS metadata, batches, exports to Dash0"

# ─────────────────────────────────────────────────────────────────────────────
step "10/10  Creating ECS service"
# ─────────────────────────────────────────────────────────────────────────────

# Check if service already exists and is active
EXISTING_SVC=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" --region "${REGION}" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null || true)

if [[ "${EXISTING_SVC}" == "${SERVICE_NAME}" ]]; then
    # Verify service is using the correct target group — can't update LB config on existing service
    SVC_TG=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" \
        --services "${SERVICE_NAME}" --region "${REGION}" \
        --query 'services[0].loadBalancers[0].targetGroupArn' --output text 2>/dev/null || true)
    if [[ "${SVC_TG}" != "${TG_ARN}" ]]; then
        info "Service points to wrong target group — recreating..."
        aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
            --desired-count 0 --region "${REGION}" &>/dev/null
        aws ecs wait services-stable --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
            --region "${REGION}" 2>/dev/null || true
        aws ecs delete-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
            --region "${REGION}" --force &>/dev/null
        # Wait for service to drain
        sleep 5
        EXISTING_SVC=""
    else
        info "Service exists, updating to latest task definition..."
        aws ecs update-service \
            --cluster "${CLUSTER_NAME}" \
            --service "${SERVICE_NAME}" \
            --task-definition "${SERVICE_NAME}" \
            --desired-count 1 \
            --region "${REGION}" \
            --query 'service.serviceName' --output text &>/dev/null
        ok "Service updated"
    fi
fi

if [[ "${EXISTING_SVC}" != "${SERVICE_NAME}" ]]; then
    aws ecs create-service \
        --cluster "${CLUSTER_NAME}" \
        --service-name "${SERVICE_NAME}" \
        --task-definition "${SERVICE_NAME}" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={
            subnets=[${SUBNET1},${SUBNET2}],
            securityGroups=[${APP_SG}],
            assignPublicIp=ENABLED
        }" \
        --load-balancers "targetGroupArn=${TG_ARN},containerName=app,containerPort=3000" \
        --health-check-grace-period-seconds 120 \
        --region "${REGION}" \
        --query 'service.serviceName' --output text
    ok "Service created"
fi

info "Waiting for service to reach steady state (~60s)..."
aws ecs wait services-stable \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --region "${REGION}"

# ─────────────────────────────────────────────────────────────────────────────
# Save final state for teardown
# ─────────────────────────────────────────────────────────────────────────────
save_state

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${G}  ✓ SETUP COMPLETE${NC}  ${DIM}(with OTel Collector sidecar)${NC}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${C}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${C}│${NC}  ${BOLD}Architecture${NC}                                             ${C}│${NC}"
echo -e "  ${C}│${NC}  app :3000 ──→ localhost:4317 ──→ OTel Collector ──→ Dash0 ${C}│${NC}"
echo -e "  ${C}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${BOLD}Collector pipeline:${NC}"
echo -e "  ${DIM}  ├─${NC} resourcedetection ${DIM}— auto-stamps cluster/task/AZ metadata${NC}"
echo -e "  ${DIM}  ├─${NC} batch             ${DIM}— groups spans before export${NC}"
echo -e "  ${DIM}  ├─${NC} filter            ${DIM}— drops /health check spans${NC}"
echo -e "  ${DIM}  └─${NC} memory_limiter    ${DIM}— back-pressure protection${NC}"
echo ""
echo -e "  ${BOLD}Your endpoint:${NC}  ${G}http://${ALB_DNS}${NC}"
echo ""
echo -e "  ${BOLD}Try these:${NC}"
echo -e "  ${DIM}  ├─${NC} curl ${C}http://${ALB_DNS}/api/order${NC}     ${DIM}# order flow (+ DynamoDB/S3 if enabled)${NC}"
echo -e "  ${DIM}  ├─${NC} curl ${C}http://${ALB_DNS}/api/inventory${NC} ${DIM}# scan orders + S3 report (AWS-only)${NC}"
echo -e "  ${DIM}  ├─${NC} curl ${C}http://${ALB_DNS}/api/slow${NC}      ${DIM}# latency spike${NC}"
echo -e "  ${DIM}  ├─${NC} curl ${C}http://${ALB_DNS}/api/error${NC}     ${DIM}# error span${NC}"
echo -e "  ${DIM}  ├─${NC} curl ${C}http://${ALB_DNS}/api/burst${NC}     ${DIM}# 10 parallel child spans${NC}"
echo -e "  ${DIM}  └─${NC} curl ${C}http://${ALB_DNS}/api/fetch${NC}     ${DIM}# outbound HTTP${NC}"
echo ""
if [[ "${ENABLE_AWS_SERVICES}" == "true" ]]; then
    echo -e "  ${BOLD}AWS services:${NC}  ${G}ENABLED${NC}"
    echo -e "  ${DIM}  ├─${NC} DynamoDB: ${C}${DYNAMO_TABLE}${NC}"
    echo -e "  ${DIM}  └─${NC} S3:       ${C}${S3_BUCKET}${NC}"
else
    echo -e "  ${BOLD}AWS services:${NC}  ${Y}DISABLED${NC} ${DIM}(set ENABLE_AWS_SERVICES=true to enable)${NC}"
fi
echo ""
echo -e "  ${Y}Fire a burst:${NC}  ./scripts/fire.sh http://${ALB_DNS}"
echo -e "  ${Y}Dash0:${NC}         https://app.dash0.com → Services → dash0-demo"
echo ""
echo -e "  ${BOLD}Reference files:${NC}"
echo -e "  ${DIM}  ├─${NC} output/task-definition-deployed.json  ${DIM}— exact task def${NC}"
echo -e "  ${DIM}  ├─${NC} output/task-definition-template.json  ${DIM}— reusable template${NC}"
echo -e "  ${DIM}  └─${NC} collector/otel-collector-config.yaml   ${DIM}— pipeline config${NC}"
echo ""
echo -e "  ${DIM}Teardown:${NC} ./scripts/teardown.sh"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
