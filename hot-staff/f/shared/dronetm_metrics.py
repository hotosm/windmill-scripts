#requirements:
#psycopg[binary]
#httpx
#openpyxl

"""DroneTM success metrics for a time window, from the DroneTM and ScaleODM databases,
plus processing durations (Prometheus) and compute cost (OpenCost).

Window defaults to the last 90 days, so `active_users` matches the quarterly figure.

Setup:
- `dronetm_db`: postgresql resource, app credentials with host dronetm-db-prod-ro (standby, rejects writes).
- `scaleodm_db`: postgresql resource, app credentials with host scaleodm-db-ro.

Caveats:
- km2_flown sums per-task image footprints (hull + 50m buffer), so overlaps count
  twice. km2_unique unions them. Tasks without 3+ located images fall back to the
  task outline, dated by their latest task event.
- pilot_flight_days counts distinct (uploader, EXIF capture date).
- Tech support effort is not tracked anywhere (superuser is unused), so it is not
  reported. odm_jobs_failed and odm_resubmissions are the nearest signal.
- ScaleODM restarts replace the job row, so restarted failures are not counted.
  odm_resubmissions counts tasks/projects that DroneTM submitted more than once.
- Prometheus and OpenCost keep 30 days, so the cluster metrics only cover the part
  of the window within the last 30 days. cost_per_km2 is only given when the window fits.
- Durations cover all ScaleODM workflows, not only DroneTM ones, and are
  interpolated within coarse histogram buckets (1h, 2h, 4h, 8h, ...).
- Cost is the compute allocated to the drone and odm namespaces. It excludes
  idle node time, S3 storage and the shared database cluster.

TODO:
- Add AWS (S3 BucketSizeBytes / NumberOfObjects via CloudWatch) and Matomo
  (visits, unique visitors, countries) once the credentials exist.
- Track paying customers in a list of customer, project_id and ordered/delivered
  status that the script can join on.
- Decide how to log tech support effort (e.g. a GitHub label per project) so it
  can be counted.
- For quarterly cluster metrics, collect and retain monthly results before the
  30-day retention expires. Before scheduling on the 1st, add a previous-calendar-
  month window option (schedule arguments are fixed).
- Replace the database owner credentials with dedicated read-only roles;
  currently only the standby hosts enforce read-only access.
"""

import base64
import io
from datetime import UTC, datetime, timedelta
from typing import TypedDict

import httpx
import psycopg
from openpyxl import Workbook
from psycopg.rows import dict_row


class postgresql(TypedDict):
    host: str
    port: int
    user: str
    password: str
    dbname: str
    sslmode: str


DEFAULT_WINDOW = timedelta(days=90)
CLUSTER_RETENTION = timedelta(days=30)

PROMETHEUS_URL = "http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
OPENCOST_URL = "http://opencost.opencost.svc.cluster.local:9003"
COST_NAMESPACES = ("drone", "odm")

# Histogram defined in k8s-infra apps/scaleodm/helm/values.yaml (workflowDefaults)
DURATION_BUCKETS = "argo_workflows_workflow_duration_seconds_bucket"

WINDOW_CTES = """
window_images AS (
    SELECT project_id, task_id, location, uploaded_by, uploaded_at,
           left(exif->>'DateTimeOriginal', 10) AS capture_day
    FROM project_images
    WHERE status NOT IN ('staged', 'duplicate', 'invalid_exif')
      AND uploaded_at >= %(start)s AND uploaded_at < %(end)s
),
image_footprints AS (
    SELECT project_id, task_id, date_trunc('month', min(uploaded_at)) AS month,
           ST_Buffer(ST_ConvexHull(ST_Collect(location))::geography, 50) AS footprint
    FROM window_images
    WHERE task_id IS NOT NULL AND location IS NOT NULL
    GROUP BY project_id, task_id
    HAVING count(*) >= 3
),
last_task_events AS (
    SELECT task_id, max(created_at) AS last_event_at,
           bool_or(state::text IN ('HAS_IMAGERY', 'READY_FOR_PROCESSING',
               'IMAGE_PROCESSING_FAILED', 'IMAGE_PROCESSING_STARTED',
               'IMAGE_PROCESSING_FINISHED')) AS had_imagery
    FROM task_events
    GROUP BY task_id
),
outline_footprints AS (
    SELECT t.project_id, t.id AS task_id, date_trunc('month', e.last_event_at) AS month,
           t.outline::geography AS footprint
    FROM tasks t
    JOIN last_task_events e ON e.task_id = t.id
    WHERE e.last_event_at >= %(start)s AND e.last_event_at < %(end)s
      AND (e.had_imagery OR t.assets_url IS NOT NULL
           OR coalesce(t.total_image_uploaded, 0) > 0)
      AND (
          SELECT count(*) FROM project_images i
          WHERE i.task_id = t.id AND i.location IS NOT NULL
            AND i.status NOT IN ('staged', 'duplicate', 'invalid_exif')
      ) < 3
),
footprints AS (
    SELECT * FROM image_footprints
    UNION ALL
    SELECT * FROM outline_footprints
),
window_activity AS (
    SELECT user_id, activity_at FROM (
        SELECT user_id, created_at AS activity_at FROM task_events
        UNION ALL
        SELECT author_id, created_at FROM projects
        UNION ALL
        SELECT uploaded_by, uploaded_at FROM project_images WHERE uploaded_by IS NOT NULL
    ) a
    WHERE activity_at >= %(start)s AND activity_at < %(end)s
)
"""

SUMMARY_SQL = f"""
WITH {WINDOW_CTES}
SELECT
    (SELECT count(*) FROM users WHERE date_registered < %(end)s) AS total_users,
    (SELECT count(*) FROM users
     WHERE date_registered >= %(start)s AND date_registered < %(end)s) AS new_users,
    (SELECT count(DISTINCT user_id) FROM window_activity) AS active_users,
    (SELECT count(*) FROM projects
     WHERE created_at >= %(start)s AND created_at < %(end)s) AS projects_created,
    (SELECT count(DISTINCT project_id) FROM footprints) AS projects_with_imagery,
    (SELECT count(*) FROM window_images) AS images_uploaded,
    (SELECT count(DISTINCT uploaded_by) FROM window_images) AS pilots,
    (SELECT count(DISTINCT (uploaded_by, capture_day)) FROM window_images
     WHERE uploaded_by IS NOT NULL AND capture_day IS NOT NULL) AS pilot_flight_days,
    (SELECT round((coalesce(sum(ST_Area(footprint)), 0) / 1e6)::numeric, 2)::float8
     FROM image_footprints) AS km2_from_images,
    (SELECT round((coalesce(sum(ST_Area(footprint)), 0) / 1e6)::numeric, 2)::float8
     FROM footprints) AS km2_flown,
    (SELECT round((coalesce(ST_Area(ST_Union(footprint::geometry)::geography), 0) / 1e6)::numeric, 2)::float8
     FROM footprints) AS km2_unique
"""

MONTHLY_SQL = f"""
WITH {WINDOW_CTES},
months AS (
    SELECT generate_series(
        date_trunc('month', %(start)s::timestamptz),
        %(end)s::timestamptz - interval '1 microsecond',
        interval '1 month'
    ) AS month
)
SELECT
    to_char(m.month, 'YYYY-MM') AS month,
    (SELECT count(*) FROM users
     WHERE date_registered < least(m.month + interval '1 month', %(end)s)) AS cumulative_users,
    (SELECT count(*) FROM users
     WHERE date_registered >= %(start)s AND date_registered < %(end)s
       AND date_trunc('month', date_registered) = m.month) AS new_users,
    (SELECT count(DISTINCT user_id) FROM window_activity
     WHERE date_trunc('month', activity_at) = m.month) AS active_users,
    (SELECT count(DISTINCT project_id) FROM footprints f
     WHERE f.month = m.month) AS projects_with_imagery,
    (SELECT count(*) FROM window_images
     WHERE date_trunc('month', uploaded_at) = m.month) AS images_uploaded,
    (SELECT round((coalesce(sum(ST_Area(footprint)), 0) / 1e6)::numeric, 2)::float8
     FROM footprints f WHERE f.month = m.month) AS km2_flown
FROM months m
ORDER BY m.month
"""

PROJECTS_SQL = f"""
WITH {WINDOW_CTES},
project_images_agg AS (
    SELECT project_id,
           count(*) AS images,
           count(DISTINCT uploaded_by) AS pilots,
           count(DISTINCT (uploaded_by, capture_day))
               FILTER (WHERE uploaded_by IS NOT NULL AND capture_day IS NOT NULL)
               AS pilot_flight_days
    FROM window_images
    GROUP BY project_id
),
project_area AS (
    SELECT project_id,
           count(*) AS tasks_imaged,
           round((sum(ST_Area(footprint)) / 1e6)::numeric, 2)::float8 AS km2_flown
    FROM footprints
    GROUP BY project_id
)
SELECT
    p.id::text AS project_id,
    p.name,
    p.created_at::date::text AS created,
    coalesce(i.images, 0) AS images,
    coalesce(i.pilots, 0) AS pilots,
    coalesce(i.pilot_flight_days, 0) AS pilot_flight_days,
    coalesce(a.tasks_imaged, 0) AS tasks_imaged,
    coalesce(a.km2_flown, 0) AS km2_flown
FROM projects p
LEFT JOIN project_images_agg i ON i.project_id = p.id
LEFT JOIN project_area a ON a.project_id = p.id
WHERE i.project_id IS NOT NULL OR a.project_id IS NOT NULL
ORDER BY km2_flown DESC, images DESC
"""

# DroneTM names jobs DTM-Task-<id> / DTM-Project-<id>, reading from s3://<bucket>/projects/<project_id>/...
PROCESSING_SQL = """
SELECT
    substring(read_s3_path FROM '/projects/([0-9a-f-]{36})/') AS project_id,
    count(*) AS odm_jobs,
    count(*) FILTER (WHERE job_status = 'completed') AS odm_jobs_completed,
    count(*) FILTER (WHERE job_status = 'failed') AS odm_jobs_failed,
    count(*) - count(DISTINCT odm_project_id) AS odm_resubmissions,
    round((coalesce(sum(extract(epoch FROM completed_at - started_at)), 0) / 3600)::numeric, 1)::float8
        AS processing_hours,
    coalesce(sum((metadata->>'image_count')::bigint), 0)::bigint AS images_processed,
    round((coalesce(sum((metadata->>'image_total_bytes')::bigint), 0) / 1e9)::numeric, 1)::float8
        AS gb_processed
FROM scaleodm_job_metadata
WHERE odm_project_id LIKE 'DTM-%%'
  AND created_at >= %(start)s AND created_at < %(end)s
GROUP BY 1
"""

PROCESSING_FIELDS = (
    "odm_jobs",
    "odm_jobs_completed",
    "odm_jobs_failed",
    "odm_resubmissions",
    "processing_hours",
    "images_processed",
    "gb_processed",
)


CONNECT_KEYS = ("host", "port", "user", "password", "dbname", "sslmode")


def query(db: postgresql, sql: str, params: dict) -> list[dict]:
    conninfo = {k: db[k] for k in CONNECT_KEYS if db.get(k)}
    with psycopg.connect(**conninfo, row_factory=dict_row) as conn:
        conn.read_only = True
        conn.execute("SET TIME ZONE 'UTC'")
        return conn.execute(sql, params).fetchall()


def resolve_window(start: datetime | None, end: datetime | None) -> dict:
    end = (end or datetime.now(UTC)).astimezone(UTC)
    start = (start or end - DEFAULT_WINDOW).astimezone(UTC)
    if start >= end:
        raise ValueError(f"start ({start}) must be before end ({end})")
    return {"start": start, "end": end}


def add_processing(summary: dict, projects: list[dict], processing: list[dict]) -> None:
    """Merge per-project ScaleODM totals into the project rows and the summary."""
    by_project = {row["project_id"]: row for row in processing}
    empty = dict.fromkeys(PROCESSING_FIELDS, 0)
    for project in projects:
        project.update({f: by_project.get(project["project_id"], empty)[f] for f in PROCESSING_FIELDS})
    for field in PROCESSING_FIELDS:
        summary[field] = round(sum(row[field] for row in processing), 1)


def duration_hours(quantile: float, at: datetime, range_days: int) -> float | None:
    promql = (
        f"histogram_quantile({quantile}, sum by (le) "
        f'(increase({DURATION_BUCKETS}{{status="Succeeded"}}[{range_days}d])))'
    )
    resp = httpx.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": promql, "time": at.isoformat()})
    resp.raise_for_status()
    result = resp.json()["data"]["result"]
    if not result or result[0]["value"][1] == "NaN":
        return None
    return round(float(result[0]["value"][1]) / 3600, 1)


def compute_cost_usd(start: datetime, end: datetime) -> float:
    params = {
        "window": f"{start:%Y-%m-%dT%H:%M:%SZ},{end:%Y-%m-%dT%H:%M:%SZ}",
        "aggregate": "namespace",
        "accumulate": "true",
    }
    resp = httpx.get(f"{OPENCOST_URL}/allocation/compute", params=params, timeout=60)
    resp.raise_for_status()
    by_namespace = resp.json()["data"][0]
    return round(sum(by_namespace[ns]["totalCost"] for ns in COST_NAMESPACES if ns in by_namespace), 2)


def cluster_metrics(window: dict, km2_flown: float) -> tuple[dict, str]:
    """Durations and cost for the window, clipped to the 30 days before now that the cluster keeps."""
    end = window["end"]
    start = max(window["start"], datetime.now(UTC) - CLUSTER_RETENTION)
    if start >= end:
        return {}, "not available, window ended over 30 days ago"
    range_days = max(1, round((end - start) / timedelta(days=1)))
    cost = compute_cost_usd(start, end)
    clipped = start > window["start"]
    metrics = {
        "odm_duration_p50_hours": duration_hours(0.5, end, range_days),
        "odm_duration_p90_hours": duration_hours(0.9, end, range_days),
        "compute_cost_usd": cost,
        "cost_per_km2_usd": round(cost / km2_flown, 2) if km2_flown and not clipped else None,
    }
    return metrics, f"{start:%Y-%m-%d} to {end:%Y-%m-%d}"


def add_rates(summary: dict, unrecorded_km2: float) -> None:
    flight_days = summary["pilot_flight_days"]
    summary["km2_per_pilot_flight_day"] = round(summary["km2_from_images"] / flight_days, 3) if flight_days else None
    summary["km2_flown_incl_unrecorded"] = round(summary["km2_flown"] + unrecorded_km2, 2)


def to_xlsx(sheets: dict[str, list[dict]]) -> str:
    """Base64 workbook with one sheet per table."""
    workbook = Workbook()
    workbook.remove(workbook.active)
    for title, rows in sheets.items():
        sheet = workbook.create_sheet(title)
        if rows:
            sheet.append(list(rows[0]))
        for row in rows:
            sheet.append(list(row.values()))
    buffer = io.BytesIO()
    workbook.save(buffer)
    return base64.b64encode(buffer.getvalue()).decode()


def main(
    dronetm_db: postgresql,
    scaleodm_db: postgresql,
    start: datetime | None = None,
    end: datetime | None = None,
    unrecorded_km2: float = 0.0,  # imagery flown outside DroneTM (e.g. ~100 for Freetown), all-time reports only
):
    window = resolve_window(start, end)
    summary = query(dronetm_db, SUMMARY_SQL, window)[0]
    monthly = query(dronetm_db, MONTHLY_SQL, window)
    projects = query(dronetm_db, PROJECTS_SQL, window)
    processing = query(scaleodm_db, PROCESSING_SQL, window)

    add_processing(summary, projects, processing)
    add_rates(summary, unrecorded_km2)
    cluster, cluster_label = cluster_metrics(window, summary["km2_flown"])

    window_label = f"{window['start']:%Y-%m-%d} to {window['end']:%Y-%m-%d}"
    summary_rows = [{"metric": k, "value": v} for k, v in summary.items()]
    cluster_rows = [{"metric": k, "value": v} for k, v in cluster.items()]
    sheets = {"summary": summary_rows, "cluster": cluster_rows, "monthly": monthly, "projects": projects}
    filename = f"dronetm_metrics_{window['start']:%Y-%m-%d}_{window['end']:%Y-%m-%d}.xlsx"
    return {
        "render_all": [
            {"file": {"content": to_xlsx(sheets), "filename": filename}},
            {"md": f"## DroneTM metrics, {window_label}"},
            {"table-row-object": summary_rows},
            {"md": f"## Processing and cost, {cluster_label}"},
            {"table-row-object": cluster_rows},
            {"md": "## By month"},
            {"table-row-object": monthly},
            {"md": "## By project"},
            {"table-row-object": projects},
        ]
    }
