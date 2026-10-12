#requirements:
#boto3

# Windmill script to publish / clear a hot-announcement banner.
#
# Writes the flat JSON that <hot-announcement src=...> fetches
# ({ version, title?, message?, variant?, startsAt?, endsAt? }) to the
# `hot-announcements` S3 bucket, then invalidates the CloudFront distribution
# that fronts it. Idempotent: re-running with unchanged inputs does nothing.
#
# Setup: create a Windmill resource of type `aws` (fields: aws_access_key_id,
# aws_secret_access_key, region=us-east-1) and select it as the `aws` argument.

import json
import hashlib
from datetime import datetime, timezone
from typing import Literal, Optional, TypedDict

import boto3


# Windmill shows a resource picker for a param typed with a class that matches a
# resource type. Create an `aws` resource with these fields (see header).
class aws(TypedDict):
    aws_access_key_id: str
    aws_secret_access_key: str
    region: str


# Fixed infra - these never change, so they aren't exposed as form fields.
BUCKET = "hot-announcements"
DISTRIBUTION_ID = "EXZ1AE8I9DFNJ"

# tool -> S3 key. Add a line here (and to the Literal below) for each new banner.
TOOL_KEYS = {
    "field-tm": "field-tm.json",
    "drone-tm": "drone-tm.json",
    "oam": "oam.json",
}

# Human-friendly banner type label -> wa-callout variant the component accepts.
BANNER_TYPES = {
    "HOT Red": "brand",
    "Green (Success)": "success",
    "Grey (Neutral)": "neutral",
    "Warning (Yellow)": "warning",
}


def main(
    aws: aws,
    tool: Literal["field-tm", "drone-tm", "oam"],
    title: str = "",
    message: str = "",
    banner_type: Literal[
        "HOT Red", "Green (Success)", "Grey (Neutral)", "Warning (Yellow)"
    ] = "HOT Red",
    starts_at: Optional[datetime] = None,
    ends_at: Optional[datetime] = None,
    version: str = "",       # blank -> auto-derived from content (edits re-show the banner)
    clear: bool = False,     # tick to remove the banner
) -> dict:
    key = TOOL_KEYS[tool]
    variant = BANNER_TYPES[banner_type]

    # Build the desired JSON.
    if clear:
        desired: dict = {}
    else:
        desired = {}
        if not version.strip():
            payload = f"{title}|{message}|{variant}|{starts_at}|{ends_at}"
            version = "hot-" + hashlib.sha256(payload.encode()).hexdigest()[:12]
        desired["version"] = version
        if title.strip():
            desired["title"] = title.strip()
        if message.strip():
            desired["message"] = message.strip()
        desired["variant"] = variant
        if starts_at:
            desired["startsAt"] = _iso_z(starts_at)
        if ends_at:
            desired["endsAt"] = _iso_z(ends_at)

    desired_bytes = json.dumps(desired, indent=2, ensure_ascii=False).encode()

    # AWS clients from the resource (accepts snake_case or camelCase fields).
    session = boto3.session.Session(
        aws_access_key_id=aws.get("aws_access_key_id") or aws.get("awsAccessKeyId"),
        aws_secret_access_key=aws.get("aws_secret_access_key") or aws.get("awsSecretAccessKey"),
        region_name=aws.get("region") or "us-east-1",
    )
    s3 = session.client("s3")

    # Idempotent: skip write + invalidation if the live object already matches.
    try:
        current = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        if json.loads(current) == desired:
            return {"changed": False, "key": key, "content": desired}
    except s3.exceptions.NoSuchKey:
        pass

    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=desired_bytes,
        ContentType="application/json",
        CacheControl="public, max-age=300",
    )

    # Deterministic caller reference -> retries don't create duplicate invalidations.
    caller_ref = "ann-" + hashlib.sha256(desired_bytes).hexdigest()[:24]
    inval = session.client("cloudfront").create_invalidation(
        DistributionId=DISTRIBUTION_ID,
        InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": [f"/{key}"]},
            "CallerReference": caller_ref,
        },
    )

    return {
        "changed": True,
        "key": key,
        "content": desired,
        "invalidation_id": inval["Invalidation"]["Id"],
    }


def _iso_z(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
