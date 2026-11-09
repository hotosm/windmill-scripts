# Raw-Data-API Metrics

Quarterly download metrics for `production-raw-data-api`, from its S3 server access logs:
rclone (one day at a time) → DuckDB → xlsx. Replaces the reporting side of
[hotosm/s3-logs-analyzer](https://github.com/hotosm/s3-logs-analyzer).

Script: [`hot-staff/f/shared/rawdata_metrics.py`](../../hot-staff/f/shared/rawdata_metrics.py)

## 1. S3 access logs reader (shared)

Read-only access to the whole `hot-server-access-logs` bucket, so any workflow that needs
access logs can reuse it. Skip if `f/shared/s3_access_logs_reader` already exists.

```bash
aws --profile admin iam create-user --user-name s3-access-logs-reader \
  --tags Key=tool,Value=s3-access-logs-reader
aws --profile admin iam put-user-policy --user-name s3-access-logs-reader --policy-name read \
  --policy-document '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetObject"],
    "Resource": ["arn:aws:s3:::hot-server-access-logs", "arn:aws:s3:::hot-server-access-logs/*"]}]}'
aws --profile admin iam create-access-key --user-name s3-access-logs-reader
```

Windmill → Resources → Add `aws` at `f/shared/s3_access_logs_reader` (key, secret, region `us-east-1`).

## 2. Test

From `hot-staff/`, with `<acct>` from `aws --profile admin sts get-caller-identity`. Try one week first,
a full quarter takes 1-2h:

```bash
pnpm dlx windmill-cli script preview f/shared/rawdata_metrics.py -d '{"aws": "$res:f/shared/s3_access_logs_reader", "logs_path": "hot-server-access-logs/<acct>/us-east-1/production-raw-data-api", "start": "2026-11-01T00:00:00Z", "end": "2026-11-08T00:00:00Z"}'
```

## 3. Deploy + schedule

```bash
pnpm dlx windmill-cli script push f/shared/rawdata_metrics.py
```

Schedules aren't synced to git, so add one in the UI:
- Script `f/shared/rawdata_metrics`, cron `0 0 6 5 1,4,7,10 *` (UTC). The 5th gives late logs time to arrive.
- Args: `aws` = `f/shared/s3_access_logs_reader`, `logs_path` as above, `start`/`end` empty (previous quarter)
- Add an error handler so failures notify someone

## Teardown

Delete the schedule. Only remove the `s3-access-logs-reader` user (access key and policy first) and its
resource if no other workflow uses them.
