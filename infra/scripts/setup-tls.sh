#!/bin/bash
# infra/scripts/setup-tls.sh
# Configura Nginx + TLS (Certbot) nas EC2s após o terraform apply.
# Pré-requisito: DNS já apontando para os IPs das instâncias.
#
# Usage:
#   ./infra/scripts/setup-tls.sh staging
#   ./infra/scripts/setup-tls.sh production
set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <staging|production>}"

AWS_REGION="${AWS_REGION:-us-east-1}"

case "$ENVIRONMENT" in
  staging)
    INSTANCE_ID="${EC2_INSTANCE_ID_STAGING:?EC2_INSTANCE_ID_STAGING required}"
    DOMAIN="staging.cloudfy.solutions"
    NGINX_CONF="staging.cloudfy.solutions.conf"
    ;;
  production)
    INSTANCE_ID="${EC2_INSTANCE_ID_PROD:?EC2_INSTANCE_ID_PROD required}"
    DOMAIN="api.cloudfy.solutions"
    NGINX_CONF="api.cloudfy.solutions.conf"
    ;;
  *)
    echo "❌ Ambiente deve ser 'staging' ou 'production'" && exit 1
    ;;
esac

EMAIL="devops@cloudfy.solutions"

echo "🔐 Configurando TLS para $DOMAIN em $INSTANCE_ID"
echo ""

# ── 1. Copiar config do Nginx via SSM ──────────────────────────────────────
NGINX_CONTENT=$(cat "nginx/$NGINX_CONF" | base64 -w 0)

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'echo $NGINX_CONTENT | base64 -d > /etc/nginx/sites-available/$DOMAIN',
    'ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN',
    'rm -f /etc/nginx/sites-enabled/default',
    'nginx -t && systemctl reload nginx',
    'echo Nginx configurado para $DOMAIN'
  ]" \
  --comment "Setup Nginx $DOMAIN" \
  --region "$AWS_REGION" \
  --query "Command.CommandId" --output text)

echo "⏳ [1/3] Aguardando configuração do Nginx (SSM: $CMD_ID)..."
_wait_ssm() {
  for i in $(seq 1 20); do
    STATUS=$(aws ssm get-command-invocation \
      --command-id "$1" --instance-id "$INSTANCE_ID" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    echo "  attempt $i — $STATUS"
    [[ "$STATUS" == "Success" ]] && return 0
    [[ "$STATUS" == "Failed"  ]] && echo "❌ Falhou" && return 1
    sleep 5
  done
}
_wait_ssm "$CMD_ID"
echo "  ✅ Nginx configurado"

# ── 2. Emitir certificado TLS via Certbot ──────────────────────────────────
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL',
    'echo Certificado emitido para $DOMAIN'
  ]" \
  --comment "Certbot TLS $DOMAIN" \
  --region "$AWS_REGION" \
  --query "Command.CommandId" --output text)

echo "⏳ [2/3] Aguardando emissão do certificado TLS..."
_wait_ssm "$CMD_ID"
echo "  ✅ Certificado TLS emitido"

# ── 3. Configurar renovação automática ──────────────────────────────────────
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    '(crontab -l 2>/dev/null; echo \"0 3 * * * certbot renew --quiet && systemctl reload nginx\") | crontab -',
    'echo Renovação automática configurada'
  ]" \
  --comment "Certbot auto-renew $DOMAIN" \
  --region "$AWS_REGION" \
  --query "Command.CommandId" --output text)

echo "⏳ [3/3] Configurando renovação automática..."
_wait_ssm "$CMD_ID"
echo "  ✅ Renovação automática configurada (cron: 3h diário)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ TLS configurado com sucesso!"
echo "   🌐 https://$DOMAIN/status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"