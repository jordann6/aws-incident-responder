from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, ECS, Fargate
from diagrams.aws.network import ALB, Route53
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SNS
from diagrams.aws.security import IAM, CertificateManager
from diagrams.saas.chat import Slack
from diagrams.onprem.iac import Terraform
from diagrams.generic.blank import Blank

graph_attrs = {"fontsize": "13", "bgcolor": "white", "pad": "0.5", "splines": "ortho"}
node_attrs = {"fontsize": "11"}

with Diagram(
    "AWS Incident Responder",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attrs,
    node_attr=node_attrs,
):
    tf = Terraform("Terraform\n(IaC)")

    with Cluster("Incident detection"):
        target = EC2("Target EC2\n(t3.micro)")
        alarm = Cloudwatch("CloudWatch Alarm\nCPU >= 80%, 2x5m")
        topic = SNS("SNS topic\nincident-alerts")
        target >> Edge(label="CPUUtilization") >> alarm >> topic

    with Cluster("n8n control plane"):
        acm = CertificateManager("ACM\nTLS cert")
        alb = ALB("ALB\nHTTPS 443")
        with Cluster("ECS Fargate"):
            n8n = Fargate("n8n\nrunbook engine")
        iam = IAM("Scoped IAM user\nreboot + describe")
        acm >> Edge(style="dashed") >> alb
        alb >> n8n
        iam >> Edge(style="dashed", label="SigV4") >> n8n

    dns = Route53("n8n.jordandesigns.work")
    slack = Slack("Slack\n#incidents")
    haiku = Blank("Claude Haiku\nincident summary")

    topic >> Edge(label="HTTPS sub") >> alb
    dns >> Edge(style="dashed") >> alb

    n8n >> Edge(label="summarize") >> haiku
    n8n >> Edge(label="incident / resolve / escalate") >> slack
    n8n >> Edge(label="RebootInstances\n+ verify alarm", style="bold") >> target

    tf >> Edge(style="dotted") >> alb
    tf >> Edge(style="dotted") >> topic
