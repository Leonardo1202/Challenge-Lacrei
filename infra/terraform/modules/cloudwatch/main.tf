locals {
  environments = {
    staging    = var.staging_instance_id
    production = var.prod_instance_id
  }

  alarms = {
    cpu_high  = { metric = "cpu_usage_user",    threshold = 80, desc = "CPU acima de 80%" }
    mem_high  = { metric = "mem_used_percent",  threshold = 85, desc = "Memoria acima de 85%" }
    disk_high = { metric = "disk_used_percent", threshold = 80, desc = "Disco acima de 80%" }
  }
}

# ── Alarmes de infraestrutura (CPU / Memória / Disco) ─────────────────────────
resource "aws_cloudwatch_metric_alarm" "app" {
  for_each = {
    for combo in flatten([
      for env, instance_id in local.environments : [
        for alarm_key, alarm in local.alarms : {
          key         = "${env}-${alarm_key}"
          env         = env
          instance_id = instance_id
          metric      = alarm.metric
          threshold   = alarm.threshold
          desc        = alarm.desc
        }
      ]
    ]) : combo.key => combo
  }

  alarm_name          = "${var.project}-${each.value.key}"
  alarm_description   = "[${upper(each.value.env)}] ${each.value.desc}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = each.value.metric
  namespace           = "Lacrei/${each.value.env}"
  period              = 300
  statistic           = "Average"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = each.value.instance_id }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = { Environment = each.value.env }
}

# ── Alarme de disponibilidade HTTP — /health ──────────────────────────────────
# Usa o CloudWatch Synthetics (canary) ou, de forma simples, um alarme sobre
# métricas de status code do Nginx publicadas via CloudWatch Agent.
# Para uma abordagem sem agente extra, usamos um alarme de ausência de logs
# (treat_missing_data = breaching) como indicador de que o serviço está fora.
resource "aws_cloudwatch_metric_alarm" "http_availability" {
  for_each = local.environments

  alarm_name          = "${var.project}-${each.key}-http-availability"
  alarm_description   = "[${upper(each.key)}] Aplicacao sem resposta HTTP nos ultimos 10 minutos"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyRequestCount"
  namespace           = "Lacrei/${each.key}"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = { InstanceId = each.value }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = { Environment = each.key }
}

# ── Log Groups ────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  for_each          = toset(["staging", "production"])
  name              = "/lacrei/${each.key}/app"
  retention_in_days = 30
  tags              = { Environment = each.key }
}

resource "aws_cloudwatch_log_group" "nginx_access" {
  for_each          = toset(["staging", "production"])
  name              = "/lacrei/${each.key}/nginx-access"
  retention_in_days = 14
  tags              = { Environment = each.key }
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  for_each          = toset(["staging", "production"])
  name              = "/lacrei/${each.key}/nginx-error"
  retention_in_days = 14
  tags              = { Environment = each.key }
}

# ── Filtro de métricas para erros HTTP 5xx (Nginx) ────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "http_5xx" {
  for_each = toset(["staging", "production"])

  name           = "${var.project}-${each.key}-http-5xx"
  log_group_name = aws_cloudwatch_log_group.nginx_access[each.key].name
  pattern        = "[ip, identity, user, timestamp, request, status_code=5*, size]"

  metric_transformation {
    name      = "Http5xxCount"
    namespace = "Lacrei/${each.key}"
    value     = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  for_each = toset(["staging", "production"])

  alarm_name          = "${var.project}-${each.key}-http-5xx"
  alarm_description   = "[${upper(each.key)}] Erros HTTP 5xx detectados"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Http5xxCount"
  namespace           = "Lacrei/${each.key}"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = { Environment = each.key }
}

# ── Dashboard CloudWatch ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "lacrei" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # ── Título ──────────────────────────────────────────────────────────────
      {
        type   = "text"
        x      = 0; y = 0; width = 24; height = 1
        properties = {
          markdown = "## Lacrei Saúde — Overview de Infraestrutura"
        }
      },

      # ── CPU Staging ─────────────────────────────────────────────────────────
      {
        type   = "metric"
        x      = 0; y = 1; width = 8; height = 6
        properties = {
          title  = "CPU — Staging"
          region = var.aws_region
          metrics = [[
            "Lacrei/staging", "cpu_usage_user",
            "InstanceId", var.staging_instance_id,
            { stat = "Average", period = 300 }
          ]]
          view  = "timeSeries"
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ label = "Threshold 80%", value = 80, color = "#ff6961" }]
          }
        }
      },

      # ── CPU Production ──────────────────────────────────────────────────────
      {
        type   = "metric"
        x      = 8; y = 1; width = 8; height = 6
        properties = {
          title  = "CPU — Production"
          region = var.aws_region
          metrics = [[
            "Lacrei/production", "cpu_usage_user",
            "InstanceId", var.prod_instance_id,
            { stat = "Average", period = 300 }
          ]]
          view  = "timeSeries"
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ label = "Threshold 80%", value = 80, color = "#ff6961" }]
          }
        }
      },

      # ── Memória Production ──────────────────────────────────────────────────
      {
        type   = "metric"
        x      = 16; y = 1; width = 8; height = 6
        properties = {
          title  = "Memoria — Production"
          region = var.aws_region
          metrics = [[
            "Lacrei/production", "mem_used_percent",
            "InstanceId", var.prod_instance_id,
            { stat = "Average", period = 300 }
          ]]
          view  = "timeSeries"
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ label = "Threshold 85%", value = 85, color = "#ff6961" }]
          }
        }
      },

      # ── Erros HTTP 5xx ──────────────────────────────────────────────────────
      {
        type   = "metric"
        x      = 0; y = 7; width = 12; height = 6
        properties = {
          title  = "Erros HTTP 5xx"
          region = var.aws_region
          metrics = [
            ["Lacrei/staging",    "Http5xxCount", { label = "Staging",    stat = "Sum", period = 60, color = "#f89256" }],
            ["Lacrei/production", "Http5xxCount", { label = "Production", stat = "Sum", period = 60, color = "#d62728" }]
          ]
          view = "timeSeries"
          annotations = {
            horizontal = [{ label = "Alerta: 10 erros/min", value = 10, color = "#ff6961" }]
          }
        }
      },

      # ── Status dos Alarmes ──────────────────────────────────────────────────
      {
        type   = "alarm"
        x      = 12; y = 7; width = 12; height = 6
        properties = {
          title  = "Status dos Alarmes"
          alarms = [for k, v in aws_cloudwatch_metric_alarm.app : v.alarm_arn]
        }
      },

      # ── Logs da aplicação — Staging ─────────────────────────────────────────
      {
        type   = "log"
        x      = 0; y = 13; width = 12; height = 6
        properties = {
          title   = "App Logs — Staging (ultimos 15min)"
          region  = var.aws_region
          query   = "SOURCE '/lacrei/staging/app' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view    = "table"
        }
      },

      # ── Logs da aplicação — Production ─────────────────────────────────────
      {
        type   = "log"
        x      = 12; y = 13; width = 12; height = 6
        properties = {
          title   = "App Logs — Production (ultimos 15min)"
          region  = var.aws_region
          query   = "SOURCE '/lacrei/production/app' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view    = "table"
        }
      }
    ]
  })
}
