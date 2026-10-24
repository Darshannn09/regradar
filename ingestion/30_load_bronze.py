"""30 | Load every source into Snowflake BRONZE: one table per source, one JSON object per row.

Full refresh: each table is emptied and reloaded from the newest local files.
Every table has the same columns: PAYLOAD (the untouched record), SOURCE_FILE, LOADED_AT.
Needs SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD (or access token) in .env.
"""
import json
import os

import pandas as pd
import snowflake.connector

from common import DATA_DIR, data_dir, env_key, newest, read_json, rel


def json_list(folder, pattern):
    f = newest(folder, pattern)
    return (rel(f).as_posix(), read_json(f)) if f else (None, [])


def csv_rows(folder, pattern):
    f = newest(folder, pattern)
    if not f:
        return None, []
    return rel(f).as_posix(), pd.read_csv(f, dtype=str, keep_default_na=False).to_dict(orient="records")


def ecfr_text():
    rows = []
    for f in sorted((DATA_DIR / "ecfr").glob("title*_part*_*.xml")):
        t, p, as_of = f.stem.split("_", 2)  # title21_part117_2026-10-21
        rows.append({"cfr_title": int(t[5:]), "cfr_part": p[4:], "as_of": as_of,
                     "xml": f.read_text(encoding="utf-8")})
    return "data/ecfr/*.xml", rows


def ecfr_versions():
    rows = []
    for f in sorted((DATA_DIR / "ecfr").glob("title*_part*_versions.json")):
        t, p, _ = f.stem.split("_", 2)
        for v in read_json(f).get("content_versions", []):
            v.update({"cfr_title": int(t[5:]), "cfr_part": p[4:]})
            rows.append(v)
    return "data/ecfr/*_versions.json", rows


def neighborhoods():
    f = newest("location", "boston_neighborhoods_*.geojson")
    if not f:
        return None, []
    return rel(f).as_posix(), [{"properties": x.get("properties"), "geometry": x.get("geometry")}
                               for x in read_json(f)["features"]]


SOURCES = [
    ("RAW_FEDERAL_REGISTER",     lambda: json_list("bronze", "federal_register_all_*.json")),
    ("RAW_ECFR",                 ecfr_text),
    ("RAW_ECFR_VERSIONS",        ecfr_versions),
    ("RAW_REGULATIONS_GOV",      lambda: json_list("regulations_gov", "documents_*.json")),
    ("RAW_CONGRESS",             lambda: json_list("congress", "bills_*.json")),
    ("RAW_MA_REGULATIONS",       lambda: json_list("ma_regulations", "ma_regulations_text.json")),
    ("RAW_MA_BILLS",             lambda: json_list("ma_bills", "ma_bills_*.json")),
    ("RAW_NAICS",                lambda: csv_rows("naics", "naics_2022.csv")),
    ("RAW_COLLEGES",             lambda: json_list("location", "colleges_ma_*.json")),
    ("RAW_CENSUS_ACS",           lambda: csv_rows("location", "census_acs_suffolk_*.csv")),
    ("RAW_BUSINESS_PATTERNS",    lambda: csv_rows("location", "business_patterns_boston_*.csv")),
    ("RAW_MBTA_STATIONS",        lambda: json_list("location", "mbta_stations_*.json")),
    ("RAW_BOSTON_NEIGHBORHOODS", neighborhoods),
    ("RAW_BOSTON_FOOD_LICENSES", lambda: csv_rows("location", "boston_food_licenses_*.csv")),
]


def load(cur, table, rows, label):
    """Write rows as newline-delimited JSON, upload to the stage, and COPY into the table."""
    path = data_dir("staging") / f"{table.lower()}.ndjson"
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, default=str) + "\n")
    cur.execute(f"CREATE TABLE IF NOT EXISTS {table} "
                "(PAYLOAD VARIANT, SOURCE_FILE STRING, LOADED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())")
    cur.execute(f"TRUNCATE TABLE {table}")
    cur.execute(f"PUT 'file://{path.resolve().as_posix()}' @RAW_STAGE/all_sources/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE")
    label = label.replace("'", "")
    cur.execute(f"""COPY INTO {table} (PAYLOAD, SOURCE_FILE)
        FROM (SELECT $1, '{label}' FROM @RAW_STAGE/all_sources/{path.name}.gz)
        FILE_FORMAT = (TYPE = JSON) FORCE = TRUE ON_ERROR = 'ABORT_STATEMENT'""")
    cur.execute(f"SELECT COUNT(*) FROM {table}")
    return cur.fetchone()[0]


def connect():
    params = dict(account=env_key("SNOWFLAKE_ACCOUNT"), user=env_key("SNOWFLAKE_USER"),
                  password=env_key("SNOWFLAKE_PASSWORD"), database="REGRADAR_DB", schema="BRONZE")
    if os.getenv("SNOWFLAKE_ROLE"):
        params["role"] = os.getenv("SNOWFLAKE_ROLE")
    conn = snowflake.connector.connect(**params)
    cur = conn.cursor()
    cur.execute(f"USE WAREHOUSE {os.getenv('SNOWFLAKE_WAREHOUSE') or 'REGRADAR_WH'}")
    cur.execute("CREATE STAGE IF NOT EXISTS RAW_STAGE FILE_FORMAT = (TYPE = JSON)")
    return conn, cur


def main():
    conn, cur = connect()
    print(f"{'Table':<26}{'Local rows':>12}{'In Snowflake':>14}  Status")
    loaded_tables, total, failed = 0, 0, 0
    try:
        for table, build in SOURCES:
            try:
                label, rows = build()
                if not rows:
                    print(f"{table:<26}{0:>12}{'-':>14}  skipped (no local file)")
                    continue
                loaded = load(cur, table, rows, label)
                ok = loaded == len(rows)
                failed += not ok
                print(f"{table:<26}{len(rows):>12,}{loaded:>14,}  {'OK' if ok else 'COUNT MISMATCH'}")
                loaded_tables, total = loaded_tables + 1, total + loaded
            except Exception as e:
                failed += 1
                print(f"{table:<26}{'':>12}{'':>14}  ERROR: {str(e).splitlines()[0][:120]}")
    finally:
        cur.close()
        conn.close()

    print(f"\nLoaded {loaded_tables} tables, {total:,} rows into REGRADAR_DB.BRONZE")
    if failed:
        raise SystemExit(f"{failed} table(s) failed. See the lines above.")


if __name__ == "__main__":
    main()
