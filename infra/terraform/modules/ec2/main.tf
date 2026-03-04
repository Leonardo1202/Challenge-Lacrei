resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-sg"
  description = "Lacrei ${var.environment} - HTTPS inbound only"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Porta 22 BLOQUEADA — acesso via SSM apenas
  # Porta 3000 BLOQUEADA — apenas Nginx acessa internamente

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-sg"
    Environment = var.environment
  }
}

locals {
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    environment     = var.environment
    aws_region      = var.aws_region
    ecr_registry    = var.ecr_registry
    allowed_origins = var.allowed_origins
  }))
}

resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = var.iam_instance_profile

  user_data_base64            = local.user_data
  user_data_replace_on_change = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
    tags = { Name = "${var.project}-${var.environment}-root" }
  }

  disable_api_termination = var.environment == "production" ? true : false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tags = {
    Name        = "${var.project}-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = "${var.project}-${var.environment}-eip" }
}
