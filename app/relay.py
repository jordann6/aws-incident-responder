"""Relay central alarm notifications from SQS to the private n8n webhook.

The ops-alarms topic (monitoring account) delivers to an SQS queue in prod with
raw message delivery, so each message body is the CloudWatch alarm JSON. This
function posts it to n8n inside the VPC; n8n has no load balancer and no public
address, and its security group admits only this function. A failed post is
reported per message, so SQS retries just that message and sends it to the
dead-letter queue after the redrive limit.
"""

import json
import os
import urllib.request

WEBHOOK_URL = os.environ["N8N_WEBHOOK_URL"]
TIMEOUT_SECONDS = 10


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        body = record["body"]
        try:
            json.loads(body)  # only alarm JSON is forwarded
            request = urllib.request.Request(  # noqa: S310 - fixed in-VPC http URL from config
                WEBHOOK_URL,
                data=body.encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as resp:  # noqa: S310  # nosec B310
                status = resp.status
            if not 200 <= status < 300:
                raise RuntimeError(f"n8n returned {status}")
            print(json.dumps({"forwarded": record["messageId"], "status": status}))
        except Exception as exc:  # noqa: BLE001 - every failure becomes a retry
            print(json.dumps({"failed": record["messageId"], "error": str(exc)}))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
