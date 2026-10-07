# Everything runs in the prod VPC's private app subnets. There is no route to an
# internet gateway there: AWS APIs go through the VPC endpoints, and the rest
# (Lambda, RDS and Bedrock APIs) through the hub firewall's domain allowlist.

resource "aws_security_group" "relay" {
  name        = "${var.name}-relay"
  description = "Relay Lambda: may reach only n8n"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-relay" }
}

resource "aws_security_group" "n8n" {
  #checkov:skip=CKV_AWS_382:Egress is HTTPS only and leaves through the hub firewall's domain allowlist.
  name        = "${var.name}-n8n"
  description = "n8n: webhook from the relay only; HTTPS out through endpoints and the hub firewall"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-n8n" }
}

resource "aws_security_group" "remediate" {
  #checkov:skip=CKV_AWS_382:Egress is HTTPS only and leaves through the hub firewall's domain allowlist.
  name        = "${var.name}-remediate"
  description = "Remediation Lambda: HTTPS out (AWS APIs, private EKS endpoint, Bedrock)"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to VPC endpoints, the private EKS API, and allowlisted APIs via the hub"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-remediate" }
}

# Separate rules, since the two groups reference each other.
resource "aws_vpc_security_group_egress_rule" "relay_to_n8n" {
  security_group_id            = aws_security_group.relay.id
  description                  = "Webhook to n8n"
  ip_protocol                  = "tcp"
  from_port                    = 5678
  to_port                      = 5678
  referenced_security_group_id = aws_security_group.n8n.id
}

resource "aws_vpc_security_group_ingress_rule" "n8n_from_relay" {
  security_group_id            = aws_security_group.n8n.id
  description                  = "Webhook from the relay Lambda only"
  ip_protocol                  = "tcp"
  from_port                    = 5678
  to_port                      = 5678
  referenced_security_group_id = aws_security_group.relay.id
}

resource "aws_vpc_security_group_egress_rule" "n8n_https" {
  security_group_id = aws_security_group.n8n.id
  description       = "HTTPS to VPC endpoints (ECR, STS, logs) and the Lambda API via the hub"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Private DNS for the webhook: the task's IP changes on every deployment.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "incident.internal"
  description = "Private names for the incident responder"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "n8n" {
  name = "n8n"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}
