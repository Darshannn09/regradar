"""
Upload the newest Federal Register file to Snowflake and load it into
REGRADAR_DB.BRONZE.RAW_FEDERAL_REGISTER.

Run:  python ingestion/load_to_bronze.py
Needs the Snowflake values in your .env file.
Tip: if password login fails because of MFA, create a Programmatic Access
Token in Snowsight and paste it as SNOWFLAKE_PASSWORD.
"""
import os
from pathlib import Path

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()

files = sorted(Path("data/bronze").glob("federal_register_*.json"))
if not files:
    raise SystemExit("No files found. Run fetch_federal_register.py first.")
latest = files[-1].resolve().as_posix()
print(f"Loading {latest}")

conn = snowflake.connector.connect(
    account=os.getenv("SNOWFLAKE_ACCOUNT"),
    user=os.getenv("SNOWFLAKE_USER"),
    password=os.getenv("SNOWFLAKE_PASSWORD"),
    role="REGRADAR_DEV",
    warehouse="REGRADAR_WH",
    database="REGRADAR_DB",
    schema="BRONZE",
)
cur = conn.cursor()
try:
    # 1. Upload the file into the internal stage
    cur.execute(
        f"PUT 'file://{latest}' @RAW_STAGE/federal_register/ "
        "AUTO_COMPRESS=TRUE OVERWRITE=TRUE"
    )

    # 2. Copy it into the raw table (Snowflake skips files it already loaded)
    cur.execute("""
        COPY INTO RAW_FEDERAL_REGISTER (PAYLOAD, SOURCE_FILE)
        FROM (SELECT $1, METADATA$FILENAME FROM @RAW_STAGE/federal_register/)
        FILE_FORMAT = (FORMAT_NAME = 'JSON_FF')
        ON_ERROR = 'CONTINUE'
    """)
    for row in cur.fetchall():
        print(row)

    cur.execute("SELECT COUNT(*) FROM RAW_FEDERAL_REGISTER")
    print(f"Rows now in RAW_FEDERAL_REGISTER: {cur.fetchone()[0]}")
finally:
    cur.close()
    conn.close()
