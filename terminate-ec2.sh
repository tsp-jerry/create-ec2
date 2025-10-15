#!/usr/bin/env bash
set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

STATE_FILE="ec2-created.env"

# 优先读取状态文件
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo "[INFO] Loaded state from $STATE_FILE"
fi

# 允许手动覆盖（例如：INSTANCE_ID=i-xxxx ALLOCATION_ID=eipalloc-xxxx ASSOC_ID=eipassoc-xxxx ./terminate-ec2.sh）
INSTANCE_ID="${INSTANCE_ID:-}"
ALLOCATION_ID="${ALLOCATION_ID:-}"
ASSOC_ID="${ASSOC_ID:-}"
NAME_TAG="${INSTANCE_NAME_TAG:-ubuntu-c5a-xl}"

if [ -z "$INSTANCE_ID" ]; then
  # 按 Name 标签尝试查找
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text | awk '{print $1}')
fi

if [ -z "$INSTANCE_ID" ]; then
  echo "[ERROR] 未找到实例。请设置 INSTANCE_ID 或确保 $STATE_FILE 存在且有效。"
  exit 1
fi

echo "[INFO] Target Instance: $INSTANCE_ID"

# 若未提供 EIP 相关信息，自动发现
if [ -z "${ASSOC_ID:-}" ] || [ -z "${ALLOCATION_ID:-}" ] || [ "$ASSOC_ID" = "None" ] || [ "$ALLOCATION_ID" = "None" ]; then
  ASSOC_ID=$(aws ec2 describe-addresses \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)
  ALLOCATION_ID=$(aws ec2 describe-addresses \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)
fi

# 1) 如有关联的 EIP，先解绑再释放（无则跳过）
if [ -n "${ASSOC_ID:-}" ] && [ "$ASSOC_ID" != "None" ]; then
  echo "[INFO] Disassociating EIP: $ASSOC_ID"
  aws ec2 disassociate-address --association-id "$ASSOC_ID" || true
fi

if [ -n "${ALLOCATION_ID:-}" ] && [ "$ALLOCATION_ID" != "None" ]; then
  echo "[INFO] Releasing EIP Allocation: $ALLOCATION_ID"
  aws ec2 release-address --allocation-id "$ALLOCATION_ID" || true
fi

# 2) 终止实例（根盘 DeleteOnTermination=true 将随实例删除）
echo "[INFO] Terminating instance: $INSTANCE_ID"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "[INFO] Instance terminated."

# 3) 清理状态文件
if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
  echo "[INFO] Removed $STATE_FILE"
fi

echo "✅ Done."
