# Values without defaults come from the gitignored lz.tfvars.json written by
# aws-landing-zone/scripts/export-incident-inputs.py.

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "incident-responder-lz"
}

variable "deploy_role_arn" {
  description = "Prod-account role Terraform deploys through"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/OrganizationAccountAccessRole$", var.deploy_role_arn))
    error_message = "Expected the prod account's OrganizationAccountAccessRole."
  }
}

variable "vpc_id" {
  type = string
}

variable "app_subnet_ids" {
  description = "Private app-tier subnets (no route to an internet gateway; egress via the hub firewall)"
  type        = list(string)
}

variable "ops_topic_arn" {
  description = "Central ops-alarms topic in the monitoring account"
  type        = string
}

variable "ops_topic_kms_key_arn" {
  description = "CMK on the ops topic; the remediation role publishes notices through it"
  type        = string
}

variable "alarm_reader_role_arn" {
  type = string
}

variable "known_alarms" {
  description = "Central alarm names the responder may act on and read"
  type        = list(string)
}

variable "remediation_role_name" {
  description = "Fixed name: the ops topic policy and the alarm reader trust it"
  type        = string
  default     = "incident-responder-lz-remediate"
}

variable "remediations" {
  description = "Alarm name -> ordered remediation actions (rds_failover, eks_scale, eks_restart). Unlisted alarms are notify-only."
  type        = map(list(string))
  default = {
    rds-cpu-high     = ["rds_failover"]
    eks-failed-nodes = ["eks_scale", "eks_restart"]
  }
}

variable "rds_instance_id" {
  type    = string
  default = "prod-postgres"
}

variable "eks_cluster_name" {
  type    = string
  default = "prod"
}

variable "eks_node_group_name" {
  type    = string
  default = "default"
}

variable "eks_restart_target" {
  description = "namespace/deployment to rollout-restart on eks-failed-nodes; empty skips the restart and its access entry"
  type        = string
  default     = ""
}

variable "claude_model" {
  description = "Claude in Amazon Bedrock model id (in-region us-east-1 endpoint). Empty skips the call and uses the template note; this account has no Anthropic model access yet (403 for Opus 5.5 and Haiku 4.5, Sonnet 5.5 and Fable 5.1 not found on this endpoint)."
  type        = string
  default     = ""
}

variable "n8n_image" {
  description = "n8n image in this account's ECR, pinned by digest (repository from the LZ incident/ root)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[0-9a-f]{64}$", var.n8n_image))
    error_message = "Use the private ECR copy pinned by digest (repo@sha256:...)."
  }
}
