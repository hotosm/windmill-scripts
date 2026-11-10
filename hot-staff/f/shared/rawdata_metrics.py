#requirements:
#duckdb

"""Raw Data API download metrics for a range of quarters, from the S3 server access logs of
the production-raw-data-api bucket. Replaces hotosm/s3-logs-analyzer for reporting.

Window: `year` and `quarter`, through `to_year` and `to_quarter` for a range, or nothing
for the previous calendar quarter. users and files_downloaded are distinct counts, so they
don't add up across months or quarters. Use the by quarter table instead of summing months.

Setup and infra: infra/rawdata_metrics/ in this repo.
- `aws`: f/shared/s3_access_logs_reader, read-only on the access logs bucket.
- `logs_path`: <bucket>/<account-id>/<region>/<source-bucket>, defaults to production-raw-data-api.

Counting is stricter than s3-logs-analyzer and the /v1/metrics API, so numbers are lower:
- A download is a distinct (day, IP, file) with a 200 or 206 GET. Many clients only fetch
  with range requests (206), and counting each request counts one download many times.
- Root files (robots.txt, favicon.ico) are ignored.
- users are distinct IPs, so shared IPs undercount and bots are included.
- exports_written counts PUTs and completed multipart uploads, so parts aren't counted twice.

S3 delivers access logs up to hours late, so run a few days after the window ends.
Logs are fetched and parsed one day at a time to keep disk and memory small.
"""

import os
import shutil
import subprocess
import tempfile
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Literal, TypedDict

import duckdb


class aws(TypedDict):
    awsAccessKeyId: str
    awsSecretAccessKey: str
    region: str


# Fields up to object size of the S3 server access log format:
# owner bucket [time] ip requester request_id operation key "uri" status error bytes_sent object_size
LOG_REGEX = (
    r'^[^ ]* [^ ]* \[([^\]]*)\] ([^ ]*) [^ ]* [^ ]* ([^ ]*) ([^ ]*) (?:"[^"]*"|-) '
    r"(-|[0-9]*) [^ ]* ([^ ]*) ([^ ]*)"
)
LOG_FIELDS = ["time", "ip", "op", "key", "status", "bytes_sent", "object_size"]
LINE_DELIMITER = "\x1f"  # never appears in logs, so each line reads as one column

# DuckDB sizes itself from the node's RAM, not the pod limit (6500Mi on the osm-export-small
# workers this runs on), so cap it and back it with a file in the job dir to spill to disk
DUCKDB_FILE = "requests.duckdb"
DUCKDB_CONFIG = {"memory_limit": "4GB", "threads": 2, "preserve_insertion_order": False}

DOWNLOAD_OP = "REST.GET.OBJECT"
EXPORT_OPS = ("REST.PUT.OBJECT", "REST.POST.UPLOAD")

LOAD_SQL = """
INSERT INTO requests
SELECT strptime(split_part(r.time, ':', 1), '%d/%b/%Y')::DATE AS day,
       r.ip, r.op, r.key, r.status,
       try_cast(r.bytes_sent AS BIGINT), try_cast(r.object_size AS BIGINT)
FROM (
    SELECT regexp_extract(line, $regex, $fields) AS r
    FROM read_csv($files, columns = {'line': 'VARCHAR'}, delim = $delim,
                  quote = '', escape = '', header = false, auto_detect = false)
)
WHERE r.op IN ($download_op, $put_op, $post_op)
  AND r.status IN ('200', '206')
  AND r.key LIKE '%/%'
"""

METRICS_SQL = """
SELECT {group} AS {label},
    count(DISTINCT (day, ip, key)) FILTER (WHERE op = $download_op) AS downloads,
    count(DISTINCT key) FILTER (WHERE op = $download_op) AS files_downloaded,
    count(DISTINCT ip) FILTER (WHERE op = $download_op) AS users,
    round(coalesce(sum(bytes_sent) FILTER (WHERE op = $download_op), 0) / 1e9, 2) AS download_gb,
    count(*) FILTER (WHERE op <> $download_op) AS exports_written,
    round(coalesce(sum(object_size) FILTER (WHERE op <> $download_op), 0) / 1e9, 2) AS export_gb
FROM requests
GROUP BY 1
ORDER BY {order}
LIMIT {limit}
"""

MONTH = "strftime(day, '%Y-%m')"
QUARTER = "strftime(day, '%Y') || '-Q' || quarter(day)"
DATASET = "split_part(key, '/', 1) || '/' || split_part(key, '/', 2)"
# Each export has its own dataset path, so a full listing runs to millions of rows
TOP_DATASETS = 20


def quarter_window(year: int, quarter: str) -> tuple[date, date]:
    first_month = 3 * int(quarter[1]) - 2
    end = date(year + 1, 1, 1) if quarter == "Q4" else date(year, first_month + 3, 1)
    return date(year, first_month, 1), end


def previous_quarter(today: date) -> tuple[date, date]:
    current = (today.month - 1) // 3 + 1
    if current == 1:
        return quarter_window(today.year - 1, "Q4")
    return quarter_window(today.year, f"Q{current - 1}")


def resolve_window(
    year: int | None, quarter: str | None, to_year: int | None, to_quarter: str | None
) -> tuple[date, date]:
    if not (year or quarter or to_year or to_quarter):
        return previous_quarter(datetime.now(UTC).date())
    if not (year and quarter):
        raise ValueError("give a year and quarter, or nothing for the previous quarter")
    start, _ = quarter_window(year, quarter)
    _, end = quarter_window(to_year or year, to_quarter or quarter)
    if start >= end:
        raise ValueError(f"{to_year or year} {to_quarter or quarter} is before {year} {quarter}")
    # A quarter still in progress would report partial numbers that look complete
    if end > datetime.now(UTC).date():
        raise ValueError(f"{to_year or year} {to_quarter or quarter} hasn't finished yet")
    return start, end


def fetch_day(remote: str, day: date, dest: Path, env: dict) -> None:
    subprocess.run(
        ["rclone", "copy", f"{remote}/{day:%Y/%m/%d}/", str(dest),
         "--transfers", "64", "--checkers", "64", "--fast-list", "--no-check-dest", "--quiet"],
        check=True,
        env=env,
    )


def load_day(con: duckdb.DuckDBPyConnection, logs_dir: Path) -> None:
    params = {
        "regex": LOG_REGEX,
        "fields": LOG_FIELDS,
        "files": f"{logs_dir}/*",
        "delim": LINE_DELIMITER,
        "download_op": DOWNLOAD_OP,
        "put_op": EXPORT_OPS[0],
        "post_op": EXPORT_OPS[1],
    }
    con.execute(LOAD_SQL, params)


def metrics(
    con: duckdb.DuckDBPyConnection, group: str, label: str, order: str = "1", limit: int | str = "NULL"
) -> list[dict]:
    sql = METRICS_SQL.format(group=group, label=label, order=order, limit=limit)
    rel = con.sql(sql, params={"download_op": DOWNLOAD_OP})
    return [dict(zip(rel.columns, row)) for row in rel.fetchall()]


def summary(con: duckdb.DuckDBPyConnection) -> list[dict]:
    totals = metrics(con, "'total'", "scope")
    row = totals[0] if totals else {}
    return [{"metric": k, "value": v} for k, v in row.items() if k != "scope"]


def create_requests_table(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("""
        CREATE TABLE requests (
            day DATE, ip VARCHAR, op VARCHAR, key VARCHAR, status VARCHAR,
            bytes_sent BIGINT, object_size BIGINT
        )
    """)


def main(
    aws: aws,
    # Windmill only reads literal defaults and inline Literal types from main's signature
    logs_path: str = "hot-server-access-logs/670261699094/us-east-1/production-raw-data-api",
    year: int | None = None,
    quarter: Literal["Q1", "Q2", "Q3", "Q4"] | None = None,
    to_year: int | None = None,
    to_quarter: Literal["Q1", "Q2", "Q3", "Q4"] | None = None,
):
    window_start, window_end = resolve_window(year, quarter, to_year, to_quarter)

    if not shutil.which("rclone"):
        subprocess.run(["apt-get", "update"], check=True)
        subprocess.run(["apt-get", "install", "-y", "--no-install-recommends", "rclone"], check=True)

    region = aws.get("region") or "us-east-1"
    remote = f":s3,provider=AWS,env_auth=true,region={region}:{logs_path.rstrip('/')}"
    env = {
        **os.environ,
        "AWS_ACCESS_KEY_ID": aws["awsAccessKeyId"],
        "AWS_SECRET_ACCESS_KEY": aws["awsSecretAccessKey"],
    }

    con = duckdb.connect(DUCKDB_FILE, config=DUCKDB_CONFIG)
    create_requests_table(con)
    total_files = 0
    day = window_start
    while day < window_end:
        with tempfile.TemporaryDirectory() as tmp:
            logs_dir = Path(tmp)
            fetch_day(remote, day, logs_dir, env)
            files = sum(1 for _ in logs_dir.iterdir())
            print(f"{day}: {files} log files")
            if files:
                load_day(con, logs_dir)
            total_files += files
        day += timedelta(days=1)

    # rclone succeeds on a missing prefix, so a wrong logs_path would otherwise report zeros
    if not total_files:
        raise RuntimeError(f"no log files under {logs_path} for {window_start} to {window_end}")

    print("building report")
    window_label = f"{window_start} to {window_end - timedelta(days=1)}"
    return {
        "render_all": [
            {"md": f"## Raw Data API downloads, {window_label}"},
            {"table-row-object": summary(con)},
            {"md": "## By quarter"},
            {"table-row-object": metrics(con, QUARTER, "quarter")},
            {"md": "## By month"},
            {"table-row-object": metrics(con, MONTH, "month")},
            {"md": f"## Top {TOP_DATASETS} datasets"},
            {"table-row-object": metrics(con, DATASET, "dataset", "downloads DESC, 1", TOP_DATASETS)},
        ]
    }
