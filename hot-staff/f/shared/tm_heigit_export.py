#requirements:
#boto3

"""Weekly anonymised Tasking Manager DB dump for HeiGIT.

pg_dump -> mask emails -> gzip -> stream to s3://<bucket>/<prefix>/<dbname>_<timestamp>.sql.gz
(default: s3://heigit-backups/tasking-manager-production/tm_production_<timestamp>.sql.gz)

Infra (networking, IAM, setup steps): infra/tm_heigit_export/ in this repo.

Setup:
- `db`: postgresql resource for the read-only `heigit_reader` user on the
  cluster-ro endpoint, dbname tm_production, sslmode=require.
- `aws`: aws resource for an IAM user with only s3:PutObject, s3:DeleteObject and
  s3:AbortMultipartUpload on arn:aws:s3:::heigit-backups/tasking-manager-production/*
  (delete/abort clean up partial uploads on failure).
- Schedule: Wednesdays 12:00 UTC (`0 0 12 * * WED`).
- The worker must be able to reach the DB on port 5432.

TM runs Postgres 15, but the worker image ships pg_dump 18. The dump is plain SQL with
pg_dump 18's `\restrict` lines, so restoring it needs psql 18.
"""

import os
import shutil
import subprocess
from datetime import datetime, timezone
from typing import TypedDict

import boto3


class postgresql(TypedDict):
    host: str
    port: int
    user: str
    password: str
    dbname: str
    sslmode: str


class aws(TypedDict):
    awsAccessKeyId: str
    awsSecretAccessKey: str
    region: str


EMAIL_SED = r"s/\b[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b/xxx@xxx.xxx/g"


def main(
    db: postgresql,
    aws: aws,
    bucket: str = "heigit-backups",
    prefix: str = "tasking-manager-production",
    endpoint_url: str = "",  # only for non-AWS S3
) -> dict:
    if not shutil.which("pg_dump"):
        subprocess.run(["apt-get", "update"], check=True)
        subprocess.run(["apt-get", "install", "-y", "--no-install-recommends", "postgresql-client"], check=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    key = "/".join(p for p in [prefix.strip("/"), f"{db['dbname']}_{timestamp}.sql.gz"] if p)

    env = {
        **os.environ,
        "PGHOST": db["host"],
        "PGPORT": str(db.get("port") or 5432),
        "PGUSER": db["user"],
        "PGPASSWORD": db["password"],
        "PGDATABASE": db["dbname"],
        "PGSSLMODE": db.get("sslmode") or "require",
    }

    s3 = boto3.client(
        "s3",
        aws_access_key_id=aws["awsAccessKeyId"],
        aws_secret_access_key=aws["awsSecretAccessKey"],
        region_name=aws.get("region") or "us-east-1",
        endpoint_url=endpoint_url or None,
    )

    print(f"Dumping {db['dbname']} to s3://{bucket}/{key}")
    proc = subprocess.Popen(
        # LC_ALL=C: byte-wise regex (much faster than UTF-8); /@/ skips the regex on lines with no email
        ["bash", "-c", f"set -o pipefail; pg_dump | LC_ALL=C sed -r '/@/{EMAIL_SED}' | gzip"],
        stdout=subprocess.PIPE,
        env=env,
    )
    try:
        s3.upload_fileobj(proc.stdout, bucket, key)
    finally:
        proc.stdout.close()
        returncode = proc.wait()

    if returncode != 0:
        s3.delete_object(Bucket=bucket, Key=key)  # don't leave a truncated dump
        raise RuntimeError(f"pg_dump failed (exit {returncode})")

    return {"bucket": bucket, "key": key}
