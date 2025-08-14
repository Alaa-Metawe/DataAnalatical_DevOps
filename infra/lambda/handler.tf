import json, os, datetime, boto3

s3 = boto3.client("s3")
BUCKET = os.environ["LANDING_BUCKET"]

def handler(event, context):
    # event is from SQS → each record holds an SNS message delivered via SQS
    ts = datetime.datetime.utcnow().strftime("%Y/%m/%d/%H")
    key_prefix = f"ingested/{ts}/"
    lines = []

    for record in event.get("Records", []):
        body = json.loads(record["body"])
        # When SNS fans out to SQS, the actual published payload sits under "Message"
        msg = body.get("Message")
        try:
            parsed = json.loads(msg)
        except Exception:
            parsed = {"raw_message": msg}
        lines.append(json.dumps(parsed))

    # write batch as a single object
    key = key_prefix + "batch.jsonl"
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=("\n".join(lines) + "\n").encode("utf-8"),
        ContentType="application/json"
    )
    return {"status": "ok", "count": len(lines), "s3_key": key}

