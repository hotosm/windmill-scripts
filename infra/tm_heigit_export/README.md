# tm_heigit_export

Weekly anonymised Tasking Manager DB dump for HeiGIT: `pg_dump` → mask emails → gzip → S3.

- Windmill script: [`hot-staff/f/shared/tm_heigit_export.py`](../../hot-staff/f/shared/tm_heigit_export.py)
- AWS resources are tagged `project=tasking-manager`, `tool=heigit-export`

## Playbook

Run from the repo root unless noted.

### 1. Network: Windmill EKS → TM Aurora

```bash
bash infra/tm_heigit_export/peering.sh
```

This peers `k8s-infra-production` (`vpc-0f2142888a4f3c3c8`, 10.0.0.0/16) with TM prod
(`vpc-0622d8fdc96a1e44d`, 172.31.0.0/16) and opens 5432 on Aurora SG `sg-0d2792bbed0ee3e75`.
Run it once. Current peering: `pcx-TODO`

### 2. DB credentials → Windmill resource

In the Windmill UI (hot-staff workspace): Resources → + Resource → type `postgresql`, saved in
folder `shared` as `tm_heigit_reader` (path `f/shared/tm_heigit_reader`):

| Field | Value |
|---|---|
| dbname | `tm_production` |
| host | `tasking-manager-rds-production.cluster-ro-ca3byyjcislk.us-east-1.rds.amazonaws.com` (read-only endpoint) |
| port | `5432` |
| password | from the secret above |
| user | `heigit_reader` |
| sslmode | `require` |

For the db password:

```bash
aws --profile admin --region us-east-1 secretsmanager get-secret-value \
  --secret-id prod/tasking-manager/heigit-db-reader --query SecretString --output text
```

### 3. S3 upload user → Windmill resource

Dumps go to `s3://heigit-backups/tasking-manager-production/tm_production_<timestamp>.sql.gz`,
the same place as the old ECS task. HeiGIT read them through the `heigit` IAM group
(`heigit-bucket-access`, read-only). This user is kept out of that group: it can only write to the prefix.

```bash
aws --profile admin iam create-user --user-name tm-heigit-export \
  --tags Key=project,Value=tasking-manager Key=tool,Value=heigit-export
aws --profile admin iam put-user-policy --user-name tm-heigit-export --policy-name s3-upload \
  --policy-document '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
    "Action": ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
    "Resource": "arn:aws:s3:::heigit-backups/tasking-manager-production/*"}]}'
aws --profile admin iam create-access-key --user-name tm-heigit-export
```

Windmill → Resources → Add `aws` at `f/shared/tm_heigit_s3_creds` (key, secret, region `us-east-1`).

### 4. Test

Connectivity (as a quick Windmill bash script):
```bash
timeout 5 bash -c '</dev/tcp/tasking-manager-rds-production.cluster-ro-ca3byyjcislk.us-east-1.rds.amazonaws.com/5432' && echo reachable
```

Full run, from `hot-staff/`:
```bash
pnpm dlx windmill-cli generate-metadata f/shared/tm_heigit_export.py
pnpm dlx windmill-cli script preview f/shared/tm_heigit_export.py -d '{"db": "$res:f/shared/tm_heigit_reader", "aws": "$res:f/shared/tm_heigit_s3_creds", "bucket": "heigit-backups", "prefix": "tasking-manager-production"}'
```

### 5. Deploy + schedule

From `hot-staff/`:
```bash
pnpm dlx windmill-cli script push f/shared/tm_heigit_export.py
```

Schedules aren't synced to git (`includeSchedules` is off), so add it in the UI: Schedules → + Schedule
- Runnable: script `f/shared/tm_heigit_export`
- Cron: `0 0 12 * * WED` (Wednesdays 12:00 UTC; Windmill cron has a seconds field first), timezone UTC
- Args: `db` = `f/shared/tm_heigit_reader`, `aws` = `f/shared/tm_heigit_s3`; bucket/prefix defaults are correct
- Turn on an error handler so a failed run notifies someone

### 6. Retire the old setup

Delete the old ECS task, its schedule, and the `prod/tasking-manager/heigit-db-reader` secret
(only after step 2).

## Teardown

Find everything: `aws --profile admin --region us-east-1 resourcegroupstaggingapi get-resources --tag-filters Key=tool,Values=heigit-export`

1. Delete the routes that target the peering, in both VPCs (routes can't be tagged)
2. Revoke the `windmill-eks` rule on `sg-0d2792bbed0ee3e75`
3. `aws --profile admin --region us-east-1 ec2 delete-vpc-peering-connection --vpc-peering-connection-id <pcx>`
4. Delete IAM user `tm-heigit-export` (delete its access key and inline policy first)

## Notes

- TM is on Postgres 15.15, but the Windmill worker image ships `pg_dump` 18, and that's what makes
  the dump. It's a plain SQL dump with pg_dump 18's `\restrict` lines, so restoring it needs `psql` 18
  (pg_restore isn't used for plain SQL). Older `psql` versions error on `\restrict`.
- Dumps over 8 MB upload in parts. On failure boto3 aborts the multipart upload
  (`s3:AbortMultipartUpload`), so no parts are left behind. As a backstop, the bucket could have a
  lifecycle rule that aborts incomplete multipart uploads after 7 days. Check
  `get-bucket-lifecycle-configuration` first: `put-bucket-lifecycle-configuration` replaces every rule.
