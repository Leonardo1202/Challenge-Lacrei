# Challenge-Lacrei



# Lacrei Saúde — DevOps Challenge

Pipeline de deploy seguro, escalável e eficiente para ambientes de staging e produção na AWS.

---

## 📋 Índice

- [Visão Geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Setup dos Ambientes](#setup-dos-ambientes)
- [Fluxo CI/CD](#fluxo-cicd)
- [Segurança](#segurança)
- [Observabilidade](#observabilidade)
- [Rollback](#rollback)
- [Erros Encontrados e Decisões](#erros-encontrados-e-decisões)
- [Checklist de Segurança](#checklist-de-segurança)
- [Proposta de Integração Asaas](#proposta-de-integração-asaas)

---

## Visão Geral

| Item | Detalhe |
|---|---|
| **Aplicação** | API Node.js com rotas `/status` e `/health` |
| **Containerização** | Docker multi-stage (test → runtime) |
| **CI/CD** | GitHub Actions com OIDC (sem chaves permanentes) |
| **Infra** | Terraform modular — 6 módulos, 36 recursos AWS |
| **Staging** | `https://staging.cloudfy.solutions` — EC2 t3.micro |
| **Produção** | `https://api.cloudfy.solutions` — EC2 t3.small |

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions                           │
│                                                                 │
│  push main ──► Build & Test ──► Deploy Staging                  │
│  tag v*.*.* ──► Build & Test ──► Deploy Production              │
└────────────────────────┬────────────────────────────────────────┘
                         │ OIDC (sem chaves)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                          AWS                                    │
│                                                                 │
│  ECR ──► SSM SendCommand ──► EC2 Staging  (98.87.216.68)        │
│                         └──► EC2 Produção (34.232.41.246)       │
│                                                                 │
│  CloudWatch Logs ◄── Docker (awslogs driver)                    │
│  CloudWatch Alarms ──► SNS ──► leolima.custodio@hotmail.com     │
└─────────────────────────────────────────────────────────────────┘
```

### Recursos AWS criados via Terraform

| Módulo | Recursos |
|---|---|
| **VPC** | VPC 10.0.0.0/16, subnet pública, IGW, route table |
| **EC2** | 2 instâncias + Elastic IP + Security Groups |
| **ECR** | Repositório privado + lifecycle policy |
| **IAM** | GitHub OIDC role + EC2 role + instance profile |
| **CloudWatch** | 6 log groups + 6 alarmes |
| **SNS** | Tópico de alertas + subscription email |

---

## Setup dos Ambientes

### Pré-requisitos

- AWS CLI configurado (`aws sts get-caller-identity`)
- Terraform >= 1.7
- Git

### 1. Clonar o repositório

```bash
git clone https://github.com/Leonardo1202/Challenge-Lacrei.git
cd Challenge-Lacrei
```

### 2. Bootstrap do state remoto

```bash
AWS_REGION=us-east-1 ./infra/scripts/bootstrap-state.sh
```

Cria o bucket S3 (`lacrei-tfstate`) e tabela DynamoDB (`lacrei-tflock`) para o state remoto com lock.

### 3. Configurar variáveis

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Editar: alert_email e github_org
```

### 4. Provisionar infraestrutura

```bash
terraform init
terraform plan -out=tfplan.out
terraform apply tfplan.out
```

### 5. Configurar DNS

Após o apply, apontar no Route 53 (ou provedor de domínio):

```
staging.cloudfy.solutions  →  A  →  <staging_public_ip>
api.cloudfy.solutions      →  A  →  <production_public_ip>
```

### 6. Configurar TLS

```bash
export AWS_REGION=us-east-1
export EC2_INSTANCE_ID_STAGING=<id>
export EC2_INSTANCE_ID_PROD=<id>

./infra/scripts/setup-tls.sh staging
./infra/scripts/setup-tls.sh production
```

### 7. Configurar GitHub

**Secrets** (Settings → Secrets and variables → Actions):

```
AWS_OIDC_ROLE_ARN        = arn:aws:iam::<account>:role/lacrei-github-actions-role
EC2_INSTANCE_ID_STAGING  = i-xxxxxxxxxxxxxxxxx
EC2_INSTANCE_ID_PROD     = i-xxxxxxxxxxxxxxxxx
SNS_ALERT_TOPIC_ARN      = arn:aws:sns:us-east-1:<account>:lacrei-alerts
```

**Variables**:

```
AWS_REGION    = us-east-1
ECR_REGISTRY  = <account>.dkr.ecr.us-east-1.amazonaws.com
ECR_REPO      = lacrei-status-api
STAGING_URL   = https://staging.cloudfy.solutions
PROD_URL      = https://api.cloudfy.solutions
```

---

## Fluxo CI/CD

```
push → main
│
├── Build & Test
│   ├── Checkout
│   ├── Configure AWS (OIDC)
│   ├── Login ECR
│   ├── Build imagem Docker (stage: runtime)
│   │   └── Testes rodando dentro do build (stage: test)
│   └── Push para ECR com tag sha-<commit>
│
└── Deploy → Staging
    ├── Configure AWS (OIDC)
    ├── SSM SendCommand → EC2 Staging
    │   ├── aws ecr get-login-password | docker login
    │   ├── docker pull <imagem>
    │   ├── docker stop/rm lacrei-app
    │   └── docker run lacrei-app
    └── Smoke test: GET /status → {"status":"ok"}


push → tag v*.*.*
│
└── Build & Test
    └── Deploy → Production (mesma lógica do staging)
        └── Smoke test: GET /status → {"status":"ok"}
```

### Testes automatizados no build

```
ok 1 - GET /status returns 200 with correct shape
ok 2 - GET /health returns 200
ok 3 - GET unknown route returns 404
```

---

## Segurança

### GitHub OIDC — sem chaves permanentes

Em vez de `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`, o pipeline usa OIDC:

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
```

Tokens temporários gerados a cada execução, sem credenciais armazenadas.

### IAM — Menor privilégio

A role do GitHub Actions tem permissões mínimas:

- `ecr:GetAuthorizationToken` — autenticação ECR
- `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, etc. — push de imagem
- `ssm:SendCommand`, `ssm:GetCommandInvocation` — deploy via SSM
- `sns:Publish` — alertas de falha

### EC2 — Sem SSH exposto

- Porta 22 **bloqueada** no Security Group
- Acesso exclusivo via **AWS Systems Manager (SSM)**
- IMDSv2 obrigatório (proteção contra SSRF)

### TLS

- Let's Encrypt com renovação automática a cada 3 horas (cron)
- TLSv1.2 e TLSv1.3 apenas
- HSTS: `max-age=63072000; includeSubDomains; preload`
- Headers de segurança: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`

### Docker

- Imagem multi-stage (build separado do runtime)
- Container roda como usuário non-root
- EBS criptografado (AES256)

---

## Observabilidade

### Logs

| Log Group | Retenção |
|---|---|
| `/lacrei/staging/app` | 30 dias |
| `/lacrei/production/app` | 30 dias |
| `/lacrei/staging/nginx-access` | 14 dias |
| `/lacrei/staging/nginx-error` | 14 dias |
| `/lacrei/production/nginx-access` | 14 dias |
| `/lacrei/production/nginx-error` | 14 dias |

### Alarmes CloudWatch

| Alarme | Threshold | Ação |
|---|---|---|
| CPU Staging | > 80% por 10min | SNS |
| CPU Production | > 80% por 10min | SNS |
| Memória Staging | > 85% por 10min | SNS |
| Memória Production | > 85% por 10min | SNS |
| Disco Staging | > 80% por 10min | SNS |
| Disco Production | > 80% por 10min | SNS |

### Acessar logs

```bash
# Logs da aplicação em tempo real
aws logs tail /lacrei/staging/app --follow --region us-east-1

# Logs do Nginx
aws logs tail /lacrei/staging/nginx-access --follow --region us-east-1
```

---

## Rollback

### Rollback automático via script

```bash
# Rollback para a versão anterior no staging
./infra/scripts/rollback.sh staging

# Rollback para uma versão específica
./infra/scripts/rollback.sh staging sha-abc1234
```

### Rollback manual

```bash
# 1. Listar imagens disponíveis no ECR
aws ecr list-images \
  --repository-name lacrei-status-api \
  --region us-east-1 \
  --query 'imageIds[?imageTag!=`null`].[imageTag]' \
  --output table

# 2. Fazer rollback via SSM
aws ssm send-command \
  --instance-ids <INSTANCE_ID> \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'docker stop lacrei-app || true',
    'docker rm lacrei-app || true',
    'docker run -d --name lacrei-app --restart unless-stopped -p 3000:3000 \
      -e NODE_ENV=staging \
      <ECR_REGISTRY>/lacrei-status-api:<VERSION_ANTERIOR>'
  ]"
```

### Estratégia de tags ECR

- `sha-<commit>` — imagem de cada commit (mantidas por 10 releases)
- `latest` — última imagem deployada
- `stable` — última imagem promovida para produção

---

## Erros Encontrados e Decisões

### 1. OIDC Provider já existia na conta
**Erro:** `EntityAlreadyExists: Provider with url https://token.actions.githubusercontent.com already exists`  
**Solução:** Importar o provider existente com `terraform import`.

### 2. Caracteres especiais em descriptions IAM/EC2
**Erro:** `ValidationError: Member must satisfy regular expression pattern`  
**Causa:** Caracteres como `—` (em dash) e `ã` não são aceitos pela AWS API.  
**Solução:** Substituir por `-` e remover acentos nas descriptions.

### 3. Limite de VPCs atingido
**Erro:** `VpcLimitExceeded: The maximum number of VPCs has been reached`  
**Solução:** Deletar VPCs não utilizadas na conta. Alternativa: solicitar aumento de limite via Service Quotas.

### 4. AWS CLI não instalada nas EC2s
**Erro:** `aws: not found` no SSM command  
**Causa:** O `user_data` instalava Docker mas não a AWS CLI.  
**Solução:** Adicionar instalação condicional da AWS CLI no início do comando SSM.

### 5. Loop no Certbot (Nginx ↔ TLS)
**Problema:** Nginx não subia sem certificado, Certbot não emitia sem Nginx.  
**Solução:** Subir Nginx com config HTTP temporária → emitir certificado via `--webroot` → restaurar config HTTPS.

### 6. Cache GHA travando o build
**Problema:** Dois steps gravando `cache-to: type=gha,mode=max` simultaneamente causavam travamento.  
**Solução:** Remover `cache-to` do segundo step (runtime build).

### 7. Trust policy OIDC com nome errado do repositório
**Erro:** `Not authorized to perform sts:AssumeRoleWithWebIdentity`  
**Causa:** `github_repo` estava como `lacrei-devops-challenge` mas o repo era `Challenge-Lacrei`.  
**Solução:** Atualizar `terraform.tfvars` e aplicar novamente.

---

## Checklist de Segurança

- [x] Credenciais AWS via OIDC (tokens temporários, sem chaves permanentes)
- [x] GitHub Secrets para todos os valores sensíveis
- [x] SSH bloqueado — acesso via SSM apenas
- [x] IMDSv2 obrigatório nas EC2s
- [x] IAM com menor privilégio (roles separadas por função)
- [x] Security Groups: apenas portas 80 e 443 abertas
- [x] TLS obrigatório (TLSv1.2+)
- [x] HSTS habilitado
- [x] Headers de segurança HTTP
- [x] EBS criptografado (AES256)
- [x] ECR com scan automático de vulnerabilidades
- [x] Container roda como usuário non-root
- [x] `disable_api_termination=true` em produção
- [x] State Terraform criptografado no S3
- [x] `.gitignore` excluindo `*.tfvars` e `.terraform/`

---

## Proposta de Integração Asaas

### Arquitetura proposta

```
GitHub Actions
│
├── Build & Test (incluindo testes de integração mock Asaas)
│
└── Deploy
    └── EC2 com variáveis de ambiente:
        ASAAS_API_KEY (via AWS Secrets Manager)
        ASAAS_ENVIRONMENT (sandbox/production)
```

### Implementação segura

```bash
# Armazenar a chave no Secrets Manager
aws secretsmanager create-secret \
  --name lacrei/asaas-api-key \
  --secret-string '{"api_key":"$aact_..."}'
```

```javascript
// Recuperar na aplicação via SDK AWS
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const client = new SecretsManagerClient({ region: 'us-east-1' });
const { SecretString } = await client.send(
  new GetSecretValueCommand({ SecretId: 'lacrei/asaas-api-key' })
);
```

### Boas práticas

- Chave Asaas **nunca** em variáveis de ambiente diretas ou código-fonte
- Ambiente `sandbox` para staging, `production` para produção
- Rotação automática da chave via Secrets Manager
- Logs de transações no CloudWatch com mascaramento de dados sensíveis
