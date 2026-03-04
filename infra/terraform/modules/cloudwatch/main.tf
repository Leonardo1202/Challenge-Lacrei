locals {
  environments = {
    staging    = var.staging_instance_id
    production = var.prod_instance_id
  }

  alarms = {
    cpu_high  = { metric = "cpu_usage_user",   threshold = 80, desc = "CPU acima de 80%" }
    mem_high  = { metric = "mem_used_percent", threshold = 85, desc = "Memória acima de 85%" }
    disk_high = { metric = "disk_used_percent", threshold = 80, desc = "Disco acima de 80%" }
  }
}

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
