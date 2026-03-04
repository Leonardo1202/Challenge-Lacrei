#!/bin/bash
# EC2 User Data — runs once at first boot
# Usage: pass ENVIRONMENT variable via EC2 tag or parameter
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-staging}"   # staging | production
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> [1/7] System update"
apt-get update -y && apt-get upgrade -y

echo "==> [2/7] Install dependencies"
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  nginx certbot python3-certbot-nginx \
  awscli jq unzip

echo "==> [3/7] Install Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

systemctl enable --now docker

echo "==> [4/7] Install CloudWatch Agent"
curl -fsSL "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -o /tmp/cwa.deb
dpkg -i /tmp/cwa.deb

# CloudWatch agent config
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWA_EOF'
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/lacrei-app.log",
            "log_group_name": "/lacrei/${ENVIRONMENT}/app",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/access.log",
            "log_group_name": "/lacrei/${ENVIRONMENT}/nginx-access",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "/lacrei/${ENVIRONMENT}/nginx-error",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Lacrei/${ENVIRONMENT}",
    "metrics_collected": {
      "cpu":    { "measurement": ["cpu_usage_idle","cpu_usage_user"], "metrics_collection_interval": 60 },
      "mem":    { "measurement": ["mem_used_percent"],                "metrics_collection_interval": 60 },
      "disk":   { "measurement": ["used_percent"],                    "resources": ["/"], "metrics_collection_interval": 60 }
    }
  }
}
CWA_EOF

# substitute ${ENVIRONMENT}
sed -i "s/\${ENVIRONMENT}/${ENVIRONMENT}/g" \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

echo "==> [5/7] Configure Docker log driver → CloudWatch"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKER_EOF'
{
  "log-driver": "awslogs",
  "log-opts": {
    "awslogs-region":        "REGION_PLACEHOLDER",
    "awslogs-group":         "/lacrei/ENV_PLACEHOLDER/app",
    "awslogs-stream":        "docker",
    "awslogs-create-group":  "true"
  }
}
DOCKER_EOF

sed -i "s/REGION_PLACEHOLDER/${AWS_REGION}/g" /etc/docker/daemon.json
sed -i "s/ENV_PLACEHOLDER/${ENVIRONMENT}/g"   /etc/docker/daemon.json
systemctl restart docker

echo "==> [6/7] Configure SSM Agent (for deployments without SSH)"
snap install amazon-ssm-agent --classic || apt-get install -y amazon-ssm-agent
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || \
  systemctl enable --now amazon-ssm-agent

echo "==> [7/7] Done — instance ready for deploy"
echo "ENVIRONMENT=${ENVIRONMENT}" >> /etc/environment
echo "AWS_REGION=${AWS_REGION}"   >> /etc/environment