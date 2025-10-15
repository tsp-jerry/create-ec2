#!/usr/bin/env bash
set -euo pipefail

# 读取 .env
if [ -f ".env" ]; then
  # shellcheck disable=SC2046,SC1091
  export $(grep -v '^\s*#' .env | grep -v '^\s*$' | sed 's/\r$//')
else
  echo "[ERROR] 未找到 .env 文件。请先复制 .env.example 为 .env 并填写配置。" >&2
  exit 1
fi

# 校验必填
: "${AWS_REGION:?请在 .env 中设置 AWS_REGION}"
: "${INSTANCE_TYPE:?请在 .env 中设置 INSTANCE_TYPE}"
: "${KEY_NAME:?请在 .env 中设置 KEY_NAME}"
: "${SECURITY_GROUP_ID:?请在 .env 中设置 SECURITY_GROUP_ID}"
: "${ROOT_VOLUME_SIZE_GB:?请在 .env 中设置 ROOT_VOLUME_SIZE_GB}"
: "${ROOT_VOLUME_TYPE:?请在 .env 中设置 ROOT_VOLUME_TYPE}"
: "${ROOT_ENCRYPTED:?请在 .env 中设置 ROOT_ENCRYPTED}"
: "${INSTANCE_NAME_TAG:?请在 .env 中设置 INSTANCE_NAME_TAG}"
: "${ALLOCATE_AND_ATTACH_EIP:?请在 .env 中设置 ALLOCATE_AND_ATTACH_EIP}"
: "${ASSOCIATE_PUBLIC_IP:?请在 .env 中设置 ASSOCIATE_PUBLIC_IP}"

export AWS_DEFAULT_REGION="$AWS_REGION"

# 如果没有配置本地 aws 凭证文件且 .env 里提供了密钥，就以环境变量形式注入
if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi

# 解析 AMI：优先 AMI_ID，否则用 SSM 参数
if [[ -n "${AMI_ID:-}" ]]; then
  SELECTED_AMI="$AMI_ID"
else
  : "${AMI_SSM_PARAM:?请在 .env 中设置 AMI_SSM_PARAM 或直接设置 AMI_ID}"
  SELECTED_AMI=$(aws ssm get-parameter \
    --name "$AMI_SSM_PARAM" \
    --query "Parameter.Value" \
    --output text)
fi
echo "[INFO] Using AMI: $SELECTED_AMI"

# 组装块设备映射
BLOCK_MAP=$(jq -cn --arg size "$ROOT_VOLUME_SIZE_GB" \
                  --arg vtype "$ROOT_VOLUME_TYPE" \
                  --argjson enc $( [[ "$ROOT_ENCRYPTED" == "true" ]] && echo true || echo false ) '
[
  {
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "VolumeSize": ($size|tonumber),
      "VolumeType": $vtype,
      "Encrypted": $enc,
      "DeleteOnTermination": true
    }
  }
]')

# 组装网络参数
NETWORK_OPTS=()
if [[ -n "${SUBNET_ID:-}" ]]; then
  NETWORK_OPTS+=(--subnet-id "$SUBNET_ID")
fi
if [[ "${ASSOCIATE_PUBLIC_IP}" == "true" ]]; then
  NETWORK_OPTS+=(--associate-public-ip-address)
fi

# 组装标签
TAG_JSON=$(jq -cn --arg name "$INSTANCE_NAME_TAG" --argjson extra "${ADDITIONAL_TAGS:-[]}" '
  [{"Key":"Name","Value":$name}] + $extra
')
TAG_SPEC="ResourceType=instance,Tags=$(echo "$TAG_JSON" | jq -c '.')"

# 用户数据
USER_DATA_OPTS=()
if [[ -n "${USER_DATA_FILE:-}" ]]; then
  if [[ -f "$USER_DATA_FILE" ]]; then
    USER_DATA_OPTS=(--user-data "file://$USER_DATA_FILE")
  else
    echo "[WARN] 未找到用户数据文件：$USER_DATA_FILE，跳过注入。"
  fi
fi

# 可选 IAM 实例角色
IAM_OPTS=()
if [[ -n "${IAM_INSTANCE_PROFILE:-}" ]]; then
  IAM_OPTS=(--iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}")
fi

# 启动实例
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$SELECTED_AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --block-device-mappings "$BLOCK_MAP" \
  --tag-specifications "$TAG_SPEC" \
  "${NETWORK_OPTS[@]}" \
  "${USER_DATA_OPTS[@]}" \
  "${IAM_OPTS[@]}" \
  --count 1 \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "[INFO] Launched instance: $INSTANCE_ID"

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "[INFO] Instance is running."

# 申请并绑定 EIP（可选）
ALLOCATION_ID=""
ASSOC_ID=""
EIP_PUBLIC_IP=""
if [[ "$ALLOCATE_AND_ATTACH_EIP" == "true" ]]; then
  ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
  EIP_PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --query 'Addresses[0].PublicIp' --output text)
  ASSOC_ID=$(aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOCATION_ID" --query 'AssociationId' --output text)
  echo "[INFO] Allocated & associated EIP: $EIP_PUBLIC_IP (AllocationId: $ALLOCATION_ID)"
fi

PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# 写状态文件
cat > ec2-created.env <<EOF
export AWS_REGION="$AWS_REGION"
export INSTANCE_ID="$INSTANCE_ID"
export EIP_PUBLIC_IP="${EIP_PUBLIC_IP}"
export ALLOCATION_ID="${ALLOCATION_ID}"
export ASSOC_ID="${ASSOC_ID}"
export INSTANCE_NAME_TAG="$INSTANCE_NAME_TAG"
EOF

echo
echo "========== EC2 READY =========="
echo "InstanceId : $INSTANCE_ID"
echo "Private IP : $PRIVATE_IP"
if [[ -n "$EIP_PUBLIC_IP" ]]; then
  echo "Elastic IP : $EIP_PUBLIC_IP"
  echo
  echo "# SSH（Ubuntu 默认用户）"
  echo "ssh -i /path/to/${KEY_NAME}.pem ubuntu@$EIP_PUBLIC_IP"
fi
echo "State file : ec2-created.env"
