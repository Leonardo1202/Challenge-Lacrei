#!/bin/bash
# infra/scripts/bootstrap-state.sh
# Cria o S3 bucket e a tabela DynamoDB necessários para o Terraform remote state.
# Execute UMA VEZ antes do primeiro `terraform init`.
#
# Usage: AWS_REGION=us-east-1 ./infra/scripts/bootstrap-state.sh
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="lacrei-tfstate-${ACCOUNT_ID}"
DYNAMO_TABLE="lacrei-tflock"

echo "🚀 Bootstrapping Terraform remote state"
echo "   Region : $AWS_REGION"
echo "   Bucket : $BUCKET_NAME"
echo "   Table  : $DYNAMO_TABLE"
echo ""

# ── S3 Bucket ──────────────────────────────────────────────────────────────
echo "[1/4] Criando bucket S3..."

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "  ⚠️  Bucket já existe — pulando criação"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  echo "  ✅ Bucket criado"
fi

# ── Versionamento (permite recuperar states anteriores) ────────────────────
echo "[2/4] Habilitando versionamento..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
echo "  ✅ Versionamento habilitado"

# ── Criptografia em repouso ────────────────────────────────────────────────
echo "[3/4] Habilitando criptografia AES-256..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Bloquear acesso público ao bucket de state
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  ✅ Criptografia habilitada e acesso público bloqueado"

# ── DynamoDB (lock table) ──────────────────────────────────────────────────
echo "[4/4] Criando tabela DynamoDB para lock..."

if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" \
   --region "$AWS_REGION" &>/dev/null; then
  echo "  ⚠️  Tabela já existe — pulando criação"
else
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  echo "  ✅ Tabela DynamoDB criada"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Bootstrap concluído! Próximos passos:"
echo ""
echo "  cd infra/terraform"
echo "  cp terraform.tfvars.example terraform.tfvars"
echo "  # editar terraform.tfvars com seus valores"
echo "  terraform init"
echo "  terraform plan"
echo "  terraform apply"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"