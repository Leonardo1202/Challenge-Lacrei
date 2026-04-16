#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# rollback.sh — Reverte o deploy de um ambiente para uma versão anterior
#
# Uso:
#   ./infra/scripts/rollback.sh <environment> [image_tag]
#
# Exemplos:
#   ./infra/scripts/rollback.sh staging              # reverte para versão anterior
#   ./infra/scripts/rollback.sh production sha-abc1234  # versão específica
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENVIRONMENT="${1:-}"
TARGET_TAG="${2:-}"

# ── Validação de argumentos ───────────────────────────────────────────────────
if [[ -z "$ENVIRONMENT" ]]; then
  echo "Uso: $0 <staging|production> [image_tag]"
  exit 1
fi

if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "Ambiente inválido: '$ENVIRONMENT'. Use 'staging' ou 'production'."
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

# ── Resolver instance ID pelo ambiente ───────────────────────────────────────
if [[ "$ENVIRONMENT" == "staging" ]]; then
  INSTANCE_ID="${EC2_INSTANCE_ID_STAGING:-}"
else
  INSTANCE_ID="${EC2_INSTANCE_ID_PROD:-}"
fi

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Erro: variável EC2_INSTANCE_ID_${ENVIRONMENT^^} não definida."
  exit 1
fi

ECR_REGISTRY="${ECR_REGISTRY:-}"
ECR_REPO="${ECR_REPO:-lacrei-status-api}"

if [[ -z "$ECR_REGISTRY" ]]; then
  echo "Erro: variável ECR_REGISTRY não definida."
  exit 1
fi

# ── Resolver tag de rollback ──────────────────────────────────────────────────
if [[ -z "$TARGET_TAG" ]]; then
  echo "Buscando versão anterior para '$ENVIRONMENT' no SSM..."
  CURRENT=$(aws ssm get-parameter \
    --name "/lacrei/${ENVIRONMENT}/current_image_tag" \
    --query "Parameter.Value" --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "none")

  if [[ "$CURRENT" == "none" ]]; then
    echo "Nenhuma versão atual registrada para '$ENVIRONMENT'. Informe a tag manualmente."
    exit 1
  fi

  # Listar as últimas imagens e pegar a penúltima (excluindo a atual, latest e stable)
  echo "Versão atual: $CURRENT"
  echo "Listando imagens disponíveis no ECR..."
  TAGS=$(aws ecr list-images \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'imageIds[?imageTag!=`null`].imageTag' \
    --output text | tr '\t' '\n' | grep "^sha-" | sort -r)

  PREV_TAG=$(echo "$TAGS" | grep -v "^${CURRENT}$" | head -1)

  if [[ -z "$PREV_TAG" ]]; then
    echo "Não foi possível encontrar uma versão anterior. Informe a tag manualmente."
    echo "Tags disponíveis:"
    echo "$TAGS"
    exit 1
  fi

  TARGET_TAG="$PREV_TAG"
fi

IMAGE="${ECR_REGISTRY}/${ECR_REPO}:${TARGET_TAG}"

# ── Confirmar rollback ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " ROLLBACK"
echo "   Ambiente  : $ENVIRONMENT"
echo "   Instância : $INSTANCE_ID"
echo "   Imagem    : $IMAGE"
echo "═══════════════════════════════════════════════════"
echo ""
read -r -p "Confirmar rollback? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Rollback cancelado."
  exit 0
fi

# ── Executar rollback via SSM ─────────────────────────────────────────────────
echo "Enviando comando SSM para $ENVIRONMENT ($INSTANCE_ID)..."

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}',
    'docker pull ${IMAGE}',
    'docker stop lacrei-app || true',
    'docker rm lacrei-app || true',
    'docker run -d --name lacrei-app --restart unless-stopped -p 3000:3000 -e NODE_ENV=${ENVIRONMENT} -e APP_VERSION=${TARGET_TAG} ${IMAGE}',
    'docker image prune -f'
  ]" \
  --region "$AWS_REGION" \
  --output text --query "Command.CommandId")

echo "SSM Command ID: $CMD_ID"
echo "Aguardando execução..."

for i in $(seq 1 30); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  echo "  tentativa $i/30 — $STATUS"
  [[ "$STATUS" == "Success" ]] && break
  [[ "$STATUS" == "Failed"  ]] && echo "Rollback falhou no SSM." && exit 1
  sleep 10
done

# ── Atualizar tag atual no SSM ────────────────────────────────────────────────
aws ssm put-parameter \
  --name "/lacrei/${ENVIRONMENT}/current_image_tag" \
  --value "$TARGET_TAG" \
  --type String --overwrite \
  --region "$AWS_REGION"

echo ""
echo "✅ Rollback concluído com sucesso!"
echo "   Ambiente : $ENVIRONMENT"
echo "   Versão   : $TARGET_TAG"
