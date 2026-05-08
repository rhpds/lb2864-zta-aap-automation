import json
import time
import logging

import psycopg2
import psycopg2.extras
from flask import Flask, render_template, jsonify

from config import Config

app = Flask(__name__)
log = logging.getLogger("gtp")

REFRESH_SQL = """
    SELECT
        m.id,
        m.name,
        m.unit,
        m.rate_per_second,
        m.baseline_total,
        m.baseline_epoch,
        m.confidence,
        m.source,
        c.slug   AS category_slug,
        c.name   AS category_name,
        c.icon   AS category_icon
    FROM metrics m
    JOIN metric_categories c ON c.id = m.category_id
    ORDER BY c.id, m.id
"""


def get_db():
    return psycopg2.connect(Config.dsn())


def fetch_metrics():
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(REFRESH_SQL)
            rows = cur.fetchall()
    finally:
        conn.close()
    now = int(time.time())
    for row in rows:
        elapsed = now - int(row["baseline_epoch"])
        row["current_total"] = int(row["baseline_total"]) + int(
            float(row["rate_per_second"]) * elapsed
        )
        row["rate_per_second"] = float(row["rate_per_second"])
        row["confidence"] = float(row["confidence"])
    return rows


def check_db_health():
    conn = None
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        return True
    except Exception as exc:
        log.warning("DB health check failed: %s", exc)
        return False
    finally:
        if conn:
            conn.close()


@app.route("/")
def dashboard():
    try:
        metrics = fetch_metrics()
        db_ok = True
    except Exception as exc:
        log.warning("Database unavailable: %s", exc)
        metrics = []
        db_ok = False
    return render_template("dashboard.html", metrics=metrics, db_ok=db_ok)


@app.route("/api/metrics")
def api_metrics():
    try:
        metrics = fetch_metrics()
        return jsonify({"status": "ok", "metrics": metrics, "ts": int(time.time())})
    except Exception as exc:
        return jsonify({"status": "error", "message": str(exc)}), 503


@app.route("/api/health")
@app.route("/health")
def api_health():
    db = check_db_health()
    status = "healthy" if db else "degraded"
    code = 200 if db else 503
    return jsonify({"status": status, "database": db, "ts": int(time.time())}), code


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    app.run(host=Config.APP_HOST, port=Config.APP_PORT, debug=False, threaded=True)
