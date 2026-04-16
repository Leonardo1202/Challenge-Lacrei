#!/bin/bash
set -euo pipefail

ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"

echo "ENVIRONMENT=$ENVIRONMENT" >> /etc/environment
echo "AWS_REGION=$AWS_REGION"   >> /etc/environment

echo "==> [1/6] Atualizar sistema"
apt-get update -y && apt-get upgrade -y

echo "==> [2/6] Instalar dependências"
apt-get install -y ca-certificates curl gnupg lsb-release nginx certbot python3-certbot-nginx unzip jq

echo "==> [3/6] Instalar Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker

cat > /etc/docker/daemon.json <<DOCKER
{
  "log-driver": "awslogs",
  "log-opts": {
    "awslogs-region":       "$AWS_REGION",
    "awslogs-group":        "/lacrei/$ENVIRONMENT/app",
    "awslogs-stream":       "docker",
    "awslogs-create-group": "true"
  }
}
DOCKER
systemctl restart docker

echo "==> [4/6] Instalar CloudWatch Agent"
curl -fsSL "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -o /tmp/cwa.deb && dpkg -i /tmp/cwa.deb

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWA
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/nginx/access.log", "log_group_name": "/lacrei/$ENVIRONMENT/nginx-access", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/nginx/error.log",  "log_group_name": "/lacrei/$ENVIRONMENT/nginx-error",  "log_stream_name": "{instance_id}" }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Lacrei/$ENVIRONMENT",
    "metrics_collected": {
      "cpu":  { "measurement": ["cpu_usage_idle","cpu_usage_user"], "metrics_collection_interval": 60 },
      "mem":  { "measurement": ["mem_used_percent"],                "metrics_collection_interval": 60 },
      "disk": { "measurement": ["used_percent"], "resources": ["/"], "metrics_collection_interval": 60 }
    }
  }
}
CWA

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

echo "==> [5/6] Instalar SSM Agent"
snap install amazon-ssm-agent --classic || apt-get install -y amazon-ssm-agent
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || \
  systemctl enable --now amazon-ssm-agent

echo "==> [6/6] Configurar Nginx inicial (HTTP)"
cat > /etc/nginx/sites-available/lacrei-app <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location /health {
        proxy_pass http://127.0.0.1:3000/health;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        access_log off;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/lacrei-app /etc/nginx/sites-enabled/lacrei-app
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx

echo "==> Bootstrap $ENVIRONMENT concluído!"
