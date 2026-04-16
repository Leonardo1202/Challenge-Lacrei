output "alarm_names" {
  value = [for k, v in aws_cloudwatch_metric_alarm.app : v.alarm_name]
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.lacrei.dashboard_name}"
}
