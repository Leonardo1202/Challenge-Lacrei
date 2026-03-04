output "alarm_names" {
  value = [for k, v in aws_cloudwatch_metric_alarm.app : v.alarm_name]
}
