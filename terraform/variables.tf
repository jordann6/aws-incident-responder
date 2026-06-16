variable "aws_region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Name prefix applied to all resources"
  default     = "incident-responder"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the project VPC"
  default     = "10.30.0.0/16"
}

variable "hosted_zone_name" {
  type        = string
  description = "Public Route 53 hosted zone that the n8n record is created in"
  default     = "jordandesigns.io"
}

variable "hosted_zone_id" {
  type        = string
  description = "Zone ID of the public hosted zone. Set explicitly because more than one zone shares the name; this is the one delegated at the registrar."
  default     = "Z06682271N1J8ZD5DZHU4"
}

variable "n8n_subdomain" {
  type        = string
  description = "Subdomain hosting the n8n control plane"
  default     = "n8n"
}

variable "n8n_image" {
  type        = string
  description = "Container image for the n8n service"
  default     = "n8nio/n8n:latest"
}

variable "n8n_basic_auth_user" {
  type        = string
  description = "Basic auth username for the n8n UI"
  default     = "admin"
}

variable "n8n_task_cpu" {
  type        = string
  description = "Fargate task CPU units"
  default     = "256"
}

variable "n8n_task_memory" {
  type        = string
  description = "Fargate task memory (MiB)"
  default     = "512"
}

variable "ssm_password_param" {
  type        = string
  description = "SSM SecureString parameter name holding the n8n basic auth password"
  default     = "/incident-responder/n8n-basic-auth-password"
}

variable "ssm_encryption_key_param" {
  type        = string
  description = "SSM SecureString parameter name holding the n8n encryption key"
  default     = "/incident-responder/n8n-encryption-key"
}

variable "target_instance_type" {
  type        = string
  description = "Instance type for the demo target EC2 instance"
  default     = "t3.micro"
}

variable "cpu_alarm_threshold" {
  type        = number
  description = "CPUUtilization percentage that trips the incident alarm"
  default     = 80
}

variable "enable_sns_subscription" {
  type        = bool
  description = "Create the SNS->n8n HTTPS subscription. Leave false for the first apply; SNS rejects an unreachable endpoint, so set true only after n8n is running and the workflow is active and able to confirm the subscription."
  default     = false
}
