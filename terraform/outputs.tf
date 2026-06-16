output "n8n_url" {
  description = "n8n UI and webhook host"
  value       = "https://${local.n8n_fqdn}"
}

output "n8n_webhook_endpoint" {
  description = "SNS delivery endpoint handled by the runbook workflow"
  value       = "https://${local.n8n_fqdn}/webhook/incident"
}

output "sns_topic_arn" {
  description = "Incident alert topic"
  value       = aws_sns_topic.incident.arn
}

output "target_instance_id" {
  description = "Demo target instance the runbook reboots"
  value       = aws_instance.target.id
}

output "alarm_name" {
  description = "CloudWatch alarm the workflow verifies during the resolve loop"
  value       = aws_cloudwatch_metric_alarm.cpu.alarm_name
}

output "n8n_iam_user" {
  description = "Scoped IAM user; create an access key for the n8n AWS credential"
  value       = aws_iam_user.n8n.name
}
