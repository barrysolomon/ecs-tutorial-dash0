#!/usr/bin/env bash
# =============================================================================
# Dash0 ECS Demo — Teardown
# Deletes everything created by setup.sh
# Usage: ./teardown.sh
# =============================================================================

# Do NOT use set -e — we want to continue on failures and clean up as much as possible
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.state"

# ── Load .env if present ────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "${key}" || "${key}" =~ ^# ]] && continue
        if [[ -z "${!key+x}" ]]; then
            export "${key}=${value}"
        fi
    done < "${ENV_FILE}"
fi

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${B}▶ $1${NC}"; }
ok()    { echo -e "${G}  ✓ $1${NC}"; }
warn()  { echo -e "${Y}  ⚠ $1${NC}"; }
fail()  { echo -e "${R}  ✗ $1${NC}"; ERRORS=$((ERRORS + 1)); }

ERRORS=0

if [[ ! -f "${STATE_FILE}" ]]; then
    echo -e "${R}  ✗ .state file not found. Run setup.sh first, or delete resources manually.${NC}"
    exit 1
fi
source "${STATE_FILE}"

# ── Helper: wait for all tasks in a cluster to stop ──
wait_for_tasks_stopped() {
    local max_wait=120
    local elapsed=0
    while (( elapsed < max_wait )); do
        RUNNING=$(aws ecs list-tasks --cluster "${CLUSTER_NAME}" --region "${REGION}" \
            --query 'taskArns' --output text 2>/dev/null || true)
        if [[ -z "${RUNNING}" || "${RUNNING}" == "None" ]]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

# ── Helper: wait for ENIs in subnets to be released ──
wait_for_enis_released() {
    local max_wait=120
    local elapsed=0
    while (( elapsed < max_wait )); do
        ENI_COUNT=$(aws ec2 describe-network-interfaces \
            --filters "Name=subnet-id,Values=${SUBNET1},${SUBNET2}" \
            --region "${REGION}" \
            --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
        if [[ "${ENI_COUNT}" == "0" ]]; then
            return 0
        fi
        echo -e "${DIM}    Waiting for ${ENI_COUNT} ENI(s) to be released...${NC}"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. ECS — scale down, stop tasks, delete service
# ═══════════════════════════════════════════════════════════════════════════════
step "Scaling down ECS service to 0"
aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --desired-count 0 \
    --region "${REGION}" &>/dev/null && ok "Service scaled to 0" || warn "Service may already be inactive"

step "Waiting for running tasks to stop"
if wait_for_tasks_stopped; then
    ok "All tasks stopped"
else
    warn "Some tasks may still be stopping — continuing anyway"
fi

step "Deleting ECS service"
aws ecs delete-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --force \
    --region "${REGION}" &>/dev/null && ok "Service deleted" || warn "Service may already be deleted"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Deregister task definitions (including delete to remove from INACTIVE list)
# ═══════════════════════════════════════════════════════════════════════════════
step "Deregistering task definitions"
TASK_DEFS=$(aws ecs list-task-definitions \
    --family-prefix "${SERVICE_NAME}" \
    --region "${REGION}" \
    --query 'taskDefinitionArns[]' --output text 2>/dev/null || true)
if [[ -n "${TASK_DEFS}" && "${TASK_DEFS}" != "None" ]]; then
    for TD in ${TASK_DEFS}; do
        aws ecs deregister-task-definition --task-definition "${TD}" \
            --region "${REGION}" &>/dev/null || true
        aws ecs delete-task-definitions --task-definitions "${TD}" \
            --region "${REGION}" &>/dev/null || true
    done
    ok "Task definitions deregistered"
else
    ok "No task definitions to deregister"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. ECS cluster
# ═══════════════════════════════════════════════════════════════════════════════
step "Deleting ECS cluster"
aws ecs delete-cluster \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" &>/dev/null && ok "Cluster deleted" || fail "Could not delete cluster"

# ═══════════════════════════════════════════════════════════════════════════════
# 4. ALB — listeners first, then ALB, wait for deletion, then target group
# ═══════════════════════════════════════════════════════════════════════════════
step "Deleting ALB listeners"
LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" \
    --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true)
if [[ -n "${LISTENER_ARNS}" && "${LISTENER_ARNS}" != "None" ]]; then
    for L in ${LISTENER_ARNS}; do
        aws elbv2 delete-listener --listener-arn "${L}" &>/dev/null || true
    done
    ok "Listeners deleted"
else
    ok "No listeners to delete"
fi

step "Deleting ALB"
aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" &>/dev/null \
    && ok "ALB deletion initiated" || warn "ALB may already be deleted"

step "Waiting for ALB to be fully deleted"
aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}" 2>/dev/null \
    && ok "ALB deleted" || warn "ALB wait timed out — will retry target group later"

step "Deleting target group"
# Target group can only be deleted after ALB is fully gone
local_retries=0
while (( local_retries < 6 )); do
    if aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" &>/dev/null; then
        ok "Target group deleted"
        break
    fi
    local_retries=$((local_retries + 1))
    if (( local_retries < 6 )); then
        sleep 10
    else
        fail "Could not delete target group after retries"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Secrets Manager
# ═══════════════════════════════════════════════════════════════════════════════
step "Deleting Secrets Manager secret"
aws secretsmanager delete-secret \
    --secret-id "${SECRET_ARN}" \
    --force-delete-without-recovery \
    --region "${REGION}" &>/dev/null && ok "Secret deleted" || warn "Secret may already be deleted"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. IAM role — detach all policies, delete inline policies, then delete role
# ═══════════════════════════════════════════════════════════════════════════════
step "Detaching & deleting IAM role"
# Detach all managed policies (discover dynamically, don't hardcode)
ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "${EXEC_ROLE_NAME}" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
if [[ -n "${ATTACHED_POLICIES}" && "${ATTACHED_POLICIES}" != "None" ]]; then
    for POLICY_ARN in ${ATTACHED_POLICIES}; do
        aws iam detach-role-policy \
            --role-name "${EXEC_ROLE_NAME}" \
            --policy-arn "${POLICY_ARN}" &>/dev/null || true
    done
fi

# Delete all inline policies (discover dynamically)
INLINE_POLICIES=$(aws iam list-role-policies \
    --role-name "${EXEC_ROLE_NAME}" \
    --query 'PolicyNames[]' --output text 2>/dev/null || true)
if [[ -n "${INLINE_POLICIES}" && "${INLINE_POLICIES}" != "None" ]]; then
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy \
            --role-name "${EXEC_ROLE_NAME}" \
            --policy-name "${POLICY_NAME}" &>/dev/null || true
    done
fi

aws iam delete-role --role-name "${EXEC_ROLE_NAME}" &>/dev/null \
    && ok "IAM role deleted" || fail "Could not delete IAM role"

# ═══════════════════════════════════════════════════════════════════════════════
# 7. VPC networking — must wait for ENIs to be released first
# ═══════════════════════════════════════════════════════════════════════════════
step "Waiting for ENIs to be released (ALB/ECS cleanup)"
if wait_for_enis_released; then
    ok "All ENIs released"
else
    warn "Some ENIs still attached — VPC deletion may fail"
fi

step "Deleting route table"
ASSOC_IDS=$(aws ec2 describe-route-tables \
    --route-table-ids "${RT_ID}" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
    --output text --region "${REGION}" 2>/dev/null || true)
if [[ -n "${ASSOC_IDS}" && "${ASSOC_IDS}" != "None" ]]; then
    for A in ${ASSOC_IDS}; do
        aws ec2 disassociate-route-table --association-id "${A}" --region "${REGION}" &>/dev/null || true
    done
fi
aws ec2 delete-route-table --route-table-id "${RT_ID}" --region "${REGION}" &>/dev/null \
    && ok "Route table deleted" || warn "Route table may already be deleted"

step "Deleting subnets"
aws ec2 delete-subnet --subnet-id "${SUBNET1}" --region "${REGION}" &>/dev/null \
    && ok "Subnet 1 deleted" || fail "Could not delete subnet ${SUBNET1}"
aws ec2 delete-subnet --subnet-id "${SUBNET2}" --region "${REGION}" &>/dev/null \
    && ok "Subnet 2 deleted" || fail "Could not delete subnet ${SUBNET2}"

step "Deleting security groups"
aws ec2 delete-security-group --group-id "${APP_SG}" --region "${REGION}" &>/dev/null \
    && ok "App SG deleted" || fail "Could not delete app SG ${APP_SG}"
aws ec2 delete-security-group --group-id "${ALB_SG}" --region "${REGION}" &>/dev/null \
    && ok "ALB SG deleted" || fail "Could not delete ALB SG ${ALB_SG}"

step "Detaching & deleting internet gateway"
aws ec2 detach-internet-gateway \
    --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" --region "${REGION}" &>/dev/null || true
aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" --region "${REGION}" &>/dev/null \
    && ok "Internet gateway deleted" || fail "Could not delete IGW ${IGW_ID}"

step "Deleting VPC"
aws ec2 delete-vpc --vpc-id "${VPC_ID}" --region "${REGION}" &>/dev/null \
    && ok "VPC deleted" || fail "Could not delete VPC ${VPC_ID}"

# ═══════════════════════════════════════════════════════════════════════════════
# 7b. AWS services — DynamoDB table, S3 bucket, task role (if created)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "${ENABLE_AWS_SERVICES:-}" == "true" ]]; then
    step "Deleting DynamoDB table"
    aws dynamodb delete-table --table-name "${DYNAMO_TABLE:-dash0demo-orders}" \
        --region "${REGION}" &>/dev/null \
        && ok "DynamoDB table deleted" || warn "DynamoDB table may already be deleted"

    step "Emptying & deleting S3 bucket"
    if [[ -n "${S3_BUCKET:-}" ]]; then
        aws s3 rm "s3://${S3_BUCKET}" --recursive --region "${REGION}" &>/dev/null || true
        aws s3api delete-bucket --bucket "${S3_BUCKET}" --region "${REGION}" &>/dev/null \
            && ok "S3 bucket deleted" || warn "S3 bucket may already be deleted"
    else
        ok "No S3 bucket to delete"
    fi

    step "Deleting task role"
    if [[ -n "${TASK_ROLE_NAME:-}" ]]; then
        # Delete inline policies
        TASK_INLINE=$(aws iam list-role-policies \
            --role-name "${TASK_ROLE_NAME}" \
            --query 'PolicyNames[]' --output text 2>/dev/null || true)
        if [[ -n "${TASK_INLINE}" && "${TASK_INLINE}" != "None" ]]; then
            for P in ${TASK_INLINE}; do
                aws iam delete-role-policy --role-name "${TASK_ROLE_NAME}" \
                    --policy-name "${P}" &>/dev/null || true
            done
        fi
        aws iam delete-role --role-name "${TASK_ROLE_NAME}" &>/dev/null \
            && ok "Task role deleted" || warn "Task role may already be deleted"
    else
        ok "No task role to delete"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 8. ECR repository (force deletes all images)
# ═══════════════════════════════════════════════════════════════════════════════
step "Deleting ECR repository"
aws ecr delete-repository \
    --repository-name "${SERVICE_NAME}" \
    --force --region "${REGION}" &>/dev/null \
    && ok "ECR repository deleted" || warn "ECR repository may already be deleted"

# ═══════════════════════════════════════════════════════════════════════════════
# 9. CloudWatch log group
# ═══════════════════════════════════════════════════════════════════════════════
step "Deleting CloudWatch log group"
aws logs delete-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${REGION}" &>/dev/null \
    && ok "Log group deleted" || warn "Log group may already be deleted"

# ═══════════════════════════════════════════════════════════════════════════════
# 10. Verify everything is gone
# ═══════════════════════════════════════════════════════════════════════════════
step "Verifying cleanup"
VERIFY_ERRORS=0

# Check ECS cluster
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --region "${REGION}" \
    --query 'clusters[?status!=`INACTIVE`].clusterName' --output text 2>/dev/null || true)
if [[ -n "${CLUSTER_STATUS}" && "${CLUSTER_STATUS}" != "None" ]]; then
    fail "ECS cluster still exists: ${CLUSTER_STATUS}"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "ECS cluster: gone"
fi

# Check ALB
ALB_STATUS=$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "gone")
if [[ "${ALB_STATUS}" != "gone" ]]; then
    fail "ALB still exists (state: ${ALB_STATUS})"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "ALB: gone"
fi

# Check VPC
VPC_STATUS=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${REGION}" \
    --query 'Vpcs[0].State' --output text 2>/dev/null || echo "gone")
if [[ "${VPC_STATUS}" != "gone" ]]; then
    fail "VPC still exists (state: ${VPC_STATUS})"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "VPC: gone"
fi

# Check IAM role
ROLE_CHECK=$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" \
    --query 'Role.RoleName' --output text 2>/dev/null || echo "gone")
if [[ "${ROLE_CHECK}" != "gone" ]]; then
    fail "IAM role still exists"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "IAM role: gone"
fi

# Check ECR
ECR_CHECK=$(aws ecr describe-repositories --repository-names "${SERVICE_NAME}" \
    --region "${REGION}" --query 'repositories[0].repositoryName' --output text 2>/dev/null || echo "gone")
if [[ "${ECR_CHECK}" != "gone" ]]; then
    fail "ECR repository still exists"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "ECR repository: gone"
fi

# Check log group
LOG_CHECK=$(aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" \
    --region "${REGION}" --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text 2>/dev/null || true)
if [[ -n "${LOG_CHECK}" && "${LOG_CHECK}" != "None" ]]; then
    fail "CloudWatch log group still exists"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
else
    ok "CloudWatch log group: gone"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
rm -f "${STATE_FILE}"

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if (( ERRORS == 0 && VERIFY_ERRORS == 0 )); then
    echo -e "${BOLD}${G}  ✓ ALL RESOURCES DELETED — NO COST WILL BE INCURRED${NC}"
else
    echo -e "${BOLD}${R}  ⚠ TEARDOWN COMPLETED WITH $((ERRORS + VERIFY_ERRORS)) ISSUE(S)${NC}"
    echo -e "${Y}    Review the output above and manually delete any remaining resources.${NC}"
fi
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
