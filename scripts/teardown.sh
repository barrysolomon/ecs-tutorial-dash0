#!/usr/bin/env bash
# =============================================================================
# Dash0 ECS Demo — Teardown
# Deletes everything created by setup.sh
# Usage: ./teardown.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.state"

if [[ ! -f "${STATE_FILE}" ]]; then
    echo -e "${R}  ✗ .state file not found. Run setup.sh first, or delete resources manually.${NC}"
    exit 1
fi
source "${STATE_FILE}"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step() { echo -e "\n${B}▶ $1${NC}"; }
ok()   { echo -e "${G}  ✓ $1${NC}"; }
warn() { echo -e "${Y}  ⚠ $1${NC}"; }

step "Scaling down ECS service"
aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --desired-count 0 \
    --region "${REGION}" &>/dev/null && ok "Service scaled to 0"

step "Deleting ECS service"
aws ecs delete-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --force \
    --region "${REGION}" &>/dev/null && ok "Service deleted"

step "Deleting ECS cluster"
aws ecs delete-cluster \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" &>/dev/null && ok "Cluster deleted"

step "Deregistering task definitions"
TASK_DEFS=$(aws ecs list-task-definitions \
    --family-prefix "${SERVICE_NAME}" \
    --region "${REGION}" \
    --query 'taskDefinitionArns[]' --output text)
for TD in ${TASK_DEFS}; do
    aws ecs deregister-task-definition --task-definition "${TD}" \
        --region "${REGION}" &>/dev/null
done
ok "Task definitions deregistered"

step "Deleting ALB listener, target group & load balancer"
LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" \
    --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true)
for L in ${LISTENER_ARNS}; do
    aws elbv2 delete-listener --listener-arn "${L}" &>/dev/null
done
aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" &>/dev/null
aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}" 2>/dev/null || true
aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" &>/dev/null
ok "ALB & target group deleted"

step "Deleting Secrets Manager secret"
aws secretsmanager delete-secret \
    --secret-id "${SECRET_ARN}" \
    --force-delete-without-recovery \
    --region "${REGION}" &>/dev/null && ok "Secret deleted"

step "Detaching & deleting IAM role"
aws iam detach-role-policy \
    --role-name "${EXEC_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    &>/dev/null || true
aws iam delete-role-policy \
    --role-name "${EXEC_ROLE_NAME}" \
    --policy-name "dash0-secret-access" &>/dev/null || true
aws iam delete-role --role-name "${EXEC_ROLE_NAME}" &>/dev/null || true
ok "IAM role deleted"

step "Deleting VPC networking"
# Route table associations & route table
ASSOC_IDS=$(aws ec2 describe-route-tables \
    --route-table-ids "${RT_ID}" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
    --output text 2>/dev/null || true)
for A in ${ASSOC_IDS}; do
    aws ec2 disassociate-route-table --association-id "${A}" &>/dev/null
done
aws ec2 delete-route-table --route-table-id "${RT_ID}" &>/dev/null || true

# Subnets
aws ec2 delete-subnet --subnet-id "${SUBNET1}" &>/dev/null || true
aws ec2 delete-subnet --subnet-id "${SUBNET2}" &>/dev/null || true
ok "Subnets deleted"

# Security groups
aws ec2 delete-security-group --group-id "${APP_SG}" &>/dev/null || true
aws ec2 delete-security-group --group-id "${ALB_SG}" &>/dev/null || true
ok "Security groups deleted"

# IGW
aws ec2 detach-internet-gateway \
    --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" &>/dev/null || true
aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" &>/dev/null || true

# VPC
aws ec2 delete-vpc --vpc-id "${VPC_ID}" &>/dev/null || true
ok "VPC deleted"

step "Deleting ECR images"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="${SERVICE_NAME}"
IMAGE_IDS=$(aws ecr list-images \
    --repository-name "${REPO_NAME}" \
    --region "${REGION}" \
    --query 'imageIds[]' --output json 2>/dev/null || echo '[]')
if [[ "${IMAGE_IDS}" != "[]" ]]; then
    echo "${IMAGE_IDS}" | \
    aws ecr batch-delete-image \
        --repository-name "${REPO_NAME}" \
        --region "${REGION}" \
        --image-ids "file:///dev/stdin" &>/dev/null || true
fi
aws ecr delete-repository \
    --repository-name "${REPO_NAME}" \
    --force --region "${REGION}" &>/dev/null || true
ok "ECR repository deleted"

step "Deleting CloudWatch log group"
aws logs delete-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${REGION}" &>/dev/null || true
ok "Log group deleted"

rm -f "${STATE_FILE}"

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${G}  ✓ ALL RESOURCES DELETED${NC}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
