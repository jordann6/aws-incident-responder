"""Render both architecture diagrams with official AWS icons.

    python3 diagram.py   (needs diagrams and Graphviz)

docs/architecture.png is the standalone deploy (terraform/), docs/architecture-lz.png
is landing zone mode (terraform/lz), the one proven live in the aws-landing-zone org.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, Fargate, Lambda
from diagrams.aws.database import RDS
from diagrams.aws.integration import SNS, SQS
from diagrams.aws.management import Cloudwatch
from diagrams.aws.ml import Bedrock
from diagrams.aws.network import ALB, Route53
from diagrams.aws.security import IAM, CertificateManager, IAMRole
from diagrams.onprem.client import User
from diagrams.onprem.network import Internet
from diagrams.saas.chat import Slack

GRAPH = {"fontsize": "18", "bgcolor": "white", "pad": "0.4", "nodesep": "0.6", "ranksep": "0.9"}
NODE = {"fontsize": "12"}
ACTION = "#b03a2e"

with Diagram(
    "AWS Incident Responder | standalone",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
):
    with Cluster("Detection"):
        target = EC2("Target EC2\nt3.micro")
        alarm = Cloudwatch("CPU >= 80%\n2 x 5 min")
        topic = SNS("incident-alerts")
        target >> alarm >> topic

    with Cluster("n8n control plane"):
        dns = Route53("n8n.jordandesigns.io")
        alb = ALB("ALB\nACM TLS")
        n8n = Fargate("n8n on Fargate\nrunbook engine")
        iam = IAM("Scoped IAM user\nreboot + describe")
        dns >> Edge(style="dashed") >> alb >> n8n
        iam >> Edge(style="dashed") >> n8n

    # Standalone calls the Anthropic Messages API directly (not Bedrock); the
    # library has no Anthropic icon, so a generic external service stands in.
    haiku = Internet("Anthropic API\nClaude Haiku summary")
    slack = Slack("#incidents")

    topic >> Edge(label="HTTPS subscription") >> alb
    n8n >> Edge(label="summarize") >> haiku
    n8n >> Edge(label="incident / resolved / escalate") >> slack
    n8n >> Edge(label="reboot, wait 60s,\nre-check alarm", color=ACTION) >> target

with Diagram(
    "AWS Incident Responder | landing zone mode",
    filename="docs/architecture-lz",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
):
    with Cluster("Shared-services account"):
        ops = SNS("ops-alarms topic\nKMS")
        reader = IAMRole("Alarm reader\nread-only")
        email = User("On-call email")

    with Cluster("Prod account | private app subnets, no ALB"):
        queue = SQS("Ops queue + DLQ")
        relay = Lambda("Relay Lambda")
        n8n = Fargate("n8n on Fargate\nimage mirrored to ECR")
        remediate = Lambda("Remediate Lambda\nsummarize / notify / act")
        nova = Bedrock("Amazon Nova Lite\nin-region")
        db = RDS("Multi-AZ RDS")
        queue >> relay >> n8n >> remediate
        remediate >> Edge(label="summary") >> nova
        remediate >> Edge(label="failover", color=ACTION) >> db

    ops >> Edge(label="forced alarm") >> queue
    remediate >> Edge(label="re-check", style="dashed") >> reader
    remediate >> Edge(label="one notice") >> email
