output "ops_queue_url" {
  value = aws_sqs_queue.ops.id
}

output "ops_dlq_url" {
  value = aws_sqs_queue.dlq.id
}

output "relay_function_name" {
  value = aws_lambda_function.relay.function_name
}

output "remediate_function_name" {
  value = aws_lambda_function.remediate.function_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "n8n_service_name" {
  value = aws_ecs_service.n8n.name
}

output "n8n_log_group" {
  value = aws_cloudwatch_log_group.n8n.name
}
