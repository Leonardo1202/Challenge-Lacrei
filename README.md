# Challenge-Lacrei
Challenge Tech Lacrei health


# lacrei-devops-challenge

Pipeline de deploy seguro, escalável e eficiente para a Lacrei Saúde.  
Ambientes de **staging** e **produção** na AWS, com Docker, GitHub Actions e EC2.

---

## Índice

1. [Arquitetura](#arquitetura)
2. [Estrutura do repositório](#estrutura-do-repositório)
3. [Setup dos ambientes AWS](#setup-dos-ambientes-aws)
4. [Fluxo CI/CD](#fluxo-cicd)
5. [Segurança](#segurança)
6. [Observabilidade](#observabilidade)
7. [Rollback](#rollback)
8. [Integração Asaas (proposta)](#integração-asaas)
9. [Checklist de segurança](#checklist-de-segurança)
10. [Erros encontrados e decisões técnicas](#erros-encontrados-e-decisões-técnicas)

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                        GitHub                               │
│                                                             │
│  push → main ──────────────────────► Deploy STAGING        │
│  git tag v*.*.* ───────────────────► Deploy PRODUCTION      │
│                                                             │
│  GitHub Actions (OIDC → IAM Role, sem chaves permanentes)  │
└──────────────┬──────────────────────────────────────────────┘
               │  docker push
               ▼
┌──────────────────────┐
│   Amazon ECR         │  Imagens privadas
│   lacrei-status-api  │  Tags: sha-<short>, v*.*.*, latest, stable
└──────────┬───────────┘
           │  SSM Run Command (sem SSH aberto)
    ┌──────┴──────────────────────────────────┐
    │                                         │
    ▼                                         ▼
┌─────────────────────┐           ┌─────────────────────┐
│  EC2 STAGING        │           │  EC2 PRODUCTION      │
│  t3.micro           │           │  t3.small            │
│                     │           │                      │
│  Nginx (HTTPS/TLS)  │           │  Nginx (HTTPS/TLS)   │
│  └─► Docker         │           │  └─► Docker          │
│      └─► Node.js    │           │      └─► Node.js     │
│                     │           │                      │
│  CloudWatch Logs    │           │  CloudWatch Logs     │
│  CloudWatch Metrics │           │  CloudWatch Metrics  │
└─────────────────────┘           └──────────────────────┘
           │                                 │
           └──────────────┬──────────────────┘
                          ▼
              ┌───────────────────────┐
              │  CloudWatch Alarms    │
              │  └─► SNS → e-mail     │
              └───────────────────────┘
```

**Decisões de arquitetura:**

| Decisão | Alternativa descartada | Motivo |
|---|---|---|
| ECR em vez de DockerHub | DockerHub público | Dados sensíveis — repositório privado dentro da própria conta AWS |
| GitHub OIDC em vez de IAM User | Access key no GitHub Secret | Sem credenciais de longa duração; token expira por execução |
| SSM Run Command em vez de SSH | SSH direto | Sem porta 22 aberta; auditoria nativa via CloudTrail |
| Nginx como reverse proxy | Porta 3000 exposta diretamente | TLS, headers de segurança e rate-limit centralizados |
| Multi-stage Dockerfile (deps → test → runtime) | Imagem única | Testes rodam no build; imagem final é mínima (sem devDeps) |

---

## Estrutura do repositório

```
lacrei-devops-challenge/
├── app/
│   ├── index.js            # API Node.js (/status, /health)
│   ├── package.json
│   └── test/
│       └── status.test.js  # Testes com Node.js test runner nativo
├── .github/
│   └── workflows/
│       └── ci-cd.yml       # Pipeline completo
├── infra/
│   └── scripts/
│       ├── ec2-userdata.sh # Bootstrap EC2 (Docker, Nginx, CWAgent, SSM)
│       └── rollback.sh     # Script de rollback manual
├── nginx/
│   └── lacrei-app.conf     # Config Nginx (HTTPS + proxy)
├── Dockerfile              # Multi-stage: deps → test → runtime
├── .dockerignore
├── .gitignore
└── README.md
```

---

## Setup dos ambientes AWS

### Pré-requisitos

- AWS CLI configurada (`aws configure`)
- Conta com permissões para EC2, ECR, IAM, SSM, CloudWatch, SNS

### 1. Criar repositório ECR

```bash
aws ecr create-repository \
  --repository-name lacrei-status-api \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1
```

### 2. Criar IAM Role para as EC2s

A role deve ter as seguintes políticas:
- `AmazonEC2ContainerRegistryReadOnly` — pull de imagens do ECR
- `CloudWatchAgentServerPolicy` — envio de logs e métricas
- `AmazonSSMManagedInstanceCore` — permite SSM Run Command (sem SSH)

```bash
# Criar a role
aws iam create-role \
  --role-name lacrei-ec2-role \
  --assume-role-policy-document file://infra/iam/ec2-trust.json

# Anexar políticas
aws iam attach-role-policy --role-name lacrei-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name lacrei-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam attach-role-policy --role-name lacrei-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Criar instance profile e associar
aws iam create-instance-profile --instance-profile-name lacrei-ec2-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name lacrei-ec2-profile \
  --role-name lacrei-ec2-role
```

### 3. Criar Security Groups

```bash
# Security Group para as EC2s
aws ec2 create-security-group \
  --group-name lacrei-app-sg \
  --description "Lacrei app — HTTPS only inbound"

SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=lacrei-app-sg \
  --query 'SecurityGroups[0].GroupId' --output text)

# Apenas HTTPS (443) e HTTP (80 para redirect) de qualquer origem
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 80  --cidr 0.0.0.0/0

# SSH BLOQUEADO — acesso via SSM apenas
# Porta 3000 NÃO exposta externamente — apenas Nginx acessa internamente
```

### 4. Lançar as EC2s

```bash
# Substitua: AMI_ID (Ubuntu 22.04 LTS), KEY_NAME, SG_ID, SUBNET_ID

# Staging
aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \
  --instance-type t3.micro \
  --iam-instance-profile Name=lacrei-ec2-profile \
  --security-group-ids $SG_ID \
  --subnet-id SUBNET_ID \
  --user-data file://infra/scripts/ec2-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lacrei-staging},{Key=Env,Value=staging}]'

# Produção
aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \
  --instance-type t3.small \
  --iam-instance-profile Name=lacrei-ec2-profile \
  --security-group-ids $SG_ID \
  --subnet-id SUBNET_ID \
  --user-data file://infra/scripts/ec2-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lacrei-production},{Key=Env,Value=production}]'
```

### 5. Configurar Nginx + TLS (Certbot)

Após a EC2 estar rodando, acesse via SSM:

```bash
# Abrir sessão SSM (sem SSH!)
aws ssm start-session --target <INSTANCE_ID>

# Dentro da instância:
sudo cp /caminho/nginx/lacrei-app.conf /etc/nginx/sites-available/lacrei-app
sudo sed -i 's/YOUR_DOMAIN/staging.seudominio.com/g' /etc/nginx/sites-available/lacrei-app
sudo ln -s /etc/nginx/sites-available/lacrei-app /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Obter certificado TLS gratuito
sudo certbot --nginx -d staging.seudominio.com --non-interactive \
  --agree-tos --email devops@seudominio.com
```

### 6. Configurar GitHub Actions

**Repository Variables** (não sensíveis):

| Variable | Valor exemplo |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `ECR_REGISTRY` | `123456789.dkr.ecr.us-east-1.amazonaws.com` |
| `ECR_REPO` | `lacrei-status-api` |
| `STAGING_URL` | `https://staging.seudominio.com` |
| `PROD_URL` | `https://api.seudominio.com` |

**Repository Secrets** (sensíveis):

| Secret | Descrição |
|---|---|
| `AWS_OIDC_ROLE_ARN` | ARN da IAM Role com trust no GitHub OIDC |
| `EC2_INSTANCE_ID_STAGING` | ID da instância de staging |
| `EC2_INSTANCE_ID_PROD` | ID da instância de produção |
| `SNS_ALERT_TOPIC_ARN` | ARN do tópico SNS para alertas |

**Configurar GitHub OIDC:**

```bash
# Criar OIDC Provider no IAM (uma vez por conta AWS)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Criar IAM Role para GitHub Actions
# Trust policy: infra/iam/github-actions-trust.json
aws iam create-role \
  --role-name lacrei-github-actions-role \
  --assume-role-policy-document file://infra/iam/github-actions-trust.json

# Políticas necessárias (princípio do menor privilégio):
# - ecr:GetAuthorizationToken + ecr:BatchGetImage + ecr:PutImage
# - ssm:SendCommand + ssm:GetCommandInvocation
# - sns:Publish
```

---

## Fluxo CI/CD

```
┌─────────────┐
│  git push   │
│  → main     │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│  JOB: build                                 │
│                                             │
│  1. Checkout                                │
│  2. OIDC → AWS (sem secrets de longa dur.)  │
│  3. Login ECR                               │
│  4. Docker build --target test              │  ◄─ Falha aqui = pipeline para
│     (testes rodam dentro do build)          │
│  5. Docker build --target runtime + push    │
│  6. Smoke test local do container           │
└──────────────────┬──────────────────────────┘
                   │  needs: build
                   ▼
┌─────────────────────────────────────────────┐
│  JOB: deploy-staging   (apenas branch main) │
│                                             │
│  1. OIDC → AWS                              │
│  2. SSM Run Command na EC2 staging          │
│     - docker pull                           │
│     - docker stop/rm atual                  │
│     - docker run nova imagem                │
│  3. Smoke test HTTP em staging              │
└─────────────────────────────────────────────┘

────────── Para produção, é necessário criar uma tag ──────────

┌─────────────┐
│  git tag    │
│  v1.2.3     │
│  git push   │
│  --tags     │
└──────┬──────┘
       │
       ▼
  [build job]  (mesmo fluxo acima)
       │
       ▼
  [deploy-staging]  (confirma que staging está saudável)
       │
       ▼
┌─────────────────────────────────────────────┐
│  JOB: deploy-production  (apenas tags v*)   │
│  Environment: production (requer aprovação) │
│                                             │
│  1. Re-tag imagem como :stable no ECR       │
│  2. SSM Run Command na EC2 produção         │
│  3. Smoke test HTTP em produção             │
└─────────────────────────────────────────────┘
       │ (em caso de falha em qualquer job)
       ▼
┌─────────────────────────────────────────────┐
│  JOB: notify-failure                        │
│  SNS → e-mail/Slack com link do run         │
└─────────────────────────────────────────────┘
```

---

## Segurança

### Gerenciamento de secrets

- **GitHub OIDC**: Nenhuma chave AWS de longa duração armazenada. O token é gerado por execução e expira automaticamente.
- **GitHub Secrets**: IDs de instância, ARNs e tópicos SNS. Nunca printados nos logs.
- **Sem SSH**: Acesso às instâncias exclusivamente via AWS SSM Session Manager. Porta 22 nunca aberta no Security Group.

### TLS/HTTPS

- Let's Encrypt (Certbot) com renovação automática via `cron`
- TLSv1.2 e TLSv1.3 apenas; ciphers seguros (Mozilla Modern)
- HSTS habilitado com `max-age=63072000` e `preload`
- Redirect automático HTTP → HTTPS no Nginx

### CORS

Configurado via variável de ambiente `ALLOWED_ORIGINS` passada ao container:
```
ALLOWED_ORIGINS=https://staging.seudominio.com,https://seudominio.com
```

### Princípio do menor privilégio

| Componente | Acesso concedido |
|---|---|
| EC2 IAM Role | ECR read-only, CloudWatch write, SSM core |
| GitHub Actions IAM Role | ECR push, SSM send-command, SNS publish |
| Container Node.js | Roda como usuário não-root (`appuser`) |
| Security Group | Apenas 80 e 443 inbound; sem porta 22; sem porta 3000 |

---

## Observabilidade

### Logs

- **Docker log driver**: `awslogs` — logs do container vão direto ao CloudWatch Logs
- **Nginx**: logs de acesso e erro no CloudWatch via CloudWatch Agent
- **Log groups**:
  - `/lacrei/staging/app`
  - `/lacrei/staging/nginx-access`
  - `/lacrei/production/app`
  - `/lacrei/production/nginx-access`

### Métricas (CloudWatch)

Namespace `Lacrei/staging` e `Lacrei/production`:
- `cpu_usage_user`
- `mem_used_percent`
- `disk/used_percent`

### Alarmes recomendados

```bash
# CPU alta em produção
aws cloudwatch put-metric-alarm \
  --alarm-name "lacrei-prod-cpu-high" \
  --metric-name cpu_usage_user \
  --namespace "Lacrei/production" \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions <SNS_TOPIC_ARN>

# Memória alta em produção
aws cloudwatch put-metric-alarm \
  --alarm-name "lacrei-prod-mem-high" \
  --metric-name mem_used_percent \
  --namespace "Lacrei/production" \
  --statistic Average \
  --period 300 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions <SNS_TOPIC_ARN>
```

---

## Rollback

### Estratégia: Revert de imagem Docker via tag

Todas as imagens são armazenadas no ECR com tags imutáveis:
- `sha-<7chars>` — toda build de branch
- `v*.*.*` — toda tag de release
- `stable` — último deploy bem-sucedido em produção

### Rollback automático (via GitHub Actions)

Crie uma nova tag apontando para o commit anterior:

```bash
git tag v1.2.2 <SHA_DO_COMMIT_ANTERIOR>
git push origin v1.2.2
```

O pipeline subirá a imagem correspondente a esse commit.

### Rollback manual (script)

```bash
export AWS_REGION=us-east-1
export ECR_REGISTRY=123456789.dkr.ecr.us-east-1.amazonaws.com
export ECR_REPO=lacrei-status-api
export EC2_INSTANCE_ID_PROD=i-0abc123def456

# Listar imagens disponíveis
aws ecr list-images --repository-name lacrei-status-api

# Executar rollback para uma tag específica
./infra/scripts/rollback.sh production v1.2.0
```

### Rollback de emergência (último estado estável)

```bash
./infra/scripts/rollback.sh production stable
```

> A tag `:stable` é atualizada automaticamente a cada deploy bem-sucedido em produção.

---

## Integração Asaas

### Proposta de fluxo (arquitetura)

A Asaas é a plataforma de pagamentos. O fluxo proposto para split de pagamento seria:

```
Cliente (app Lacrei)
       │
       │  POST /payments  { amount, payerId, providerId }
       ▼
┌──────────────────────┐
│  lacrei-status-api   │  (ou serviço dedicado de pagamentos)
│                      │
│  1. Validar request  │
│  2. Buscar dados do  │
│     provedor         │
│  3. Chamar Asaas API │
└──────────┬───────────┘
           │  POST https://api.asaas.com/v3/payments
           │  Headers: access_token: ${{ secrets.ASAAS_API_KEY }}
           │  Body: { customer, value, billingType, split: [{walletId, fixedValue}] }
           ▼
┌──────────────────────┐
│  Asaas API           │
│  Split automático:   │
│  - Lacrei (taxa)     │
│  - Profissional      │
└──────────────────────┘
           │  Webhook (paymentConfirmed)
           ▼
┌──────────────────────┐
│  POST /webhooks/asaas│
│  Atualiza status no  │
│  banco interno       │
└──────────────────────┘
```

**Segurança na integração:**
- `ASAAS_API_KEY` armazenada no AWS Secrets Manager, não no código
- Webhook validado com `asaas-access-token` header
- Endpoint de webhook em rota separada com rate-limit

---

## Checklist de segurança

- [x] Nenhuma credencial AWS hardcoded no código ou GitHub Actions
- [x] GitHub OIDC configurado (tokens temporários por execução)
- [x] Porta 22 (SSH) nunca aberta no Security Group
- [x] Acesso às instâncias exclusivamente via SSM
- [x] Container roda como usuário não-root
- [x] HTTPS/TLS obrigatório (redirect HTTP → HTTPS)
- [x] TLSv1.2+ com ciphers seguros (Mozilla Modern)
- [x] HSTS habilitado
- [x] Headers de segurança no Nginx e na aplicação
- [x] CORS configurado via variável de ambiente
- [x] ECR com scan automático de vulnerabilidades em cada push
- [x] IAM com princípio do menor privilégio
- [x] Logs centralizados no CloudWatch
- [x] Alertas de infra configurados via SNS
- [x] Rollback documentado e testável

---

## Erros encontrados e decisões técnicas

| # | Situação | Decisão |
|---|---|---|
| 1 | Docker log driver `awslogs` requer que a EC2 Role tenha `logs:CreateLogGroup` | Adicionado `"awslogs-create-group": "true"` no daemon.json e permissão `logs:*` na policy CloudWatchAgentServerPolicy |
| 2 | SSM `send-command` retorna antes da execução terminar | Implementado polling de status com `get-command-invocation` no pipeline |
| 3 | Certbot falha se Nginx não estiver respondendo na porta 80 antes da validação | Nginx configurado com rota `.well-known/acme-challenge/` antes de ativar HTTPS |
| 4 | GitHub Actions OIDC precisa de trust policy com `sub` exato do repositório | Trust policy usa `StringLike` com wildcard `repo:ORG/REPO:*` |
| 5 | `docker image prune -f` após deploy pode remover imagens de outros containers | Adicionado `--filter "until=24h"` para preservar imagens recentes |