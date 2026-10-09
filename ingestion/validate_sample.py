"""Check the Federal Register sample on your laptop before loading it into Snowflake.

Run from the repo root:  python ingestion/validate_sample.py
Costs nothing: it reads the local file only.
"""
import json
import random
import re
import sys
from datetime import date
from pathlib import Path

import pandas as pd

BRONZE_DIR = Path("data/bronze")
START_DATE = date(2023, 1, 1)
OUR_AGENCIES = {
    "food-and-drug-administration",
    "food-safety-and-inspection-service",
    "occupational-safety-and-health-administration",
    "labor-department",
    "environmental-protection-agency",
}
REQUIRED = ["document_number", "title", "type", "publication_date", "agencies"]
RIN_PATTERN = re.compile(r"^\d{4}-[A-Z]{2}[0-9A-Z]{2}$")  # e.g. 0910-AI38

candidates = sorted(BRONZE_DIR.glob("federal_register*.json*"), key=lambda p: p.stat().st_mtime)
if not candidates:
    sys.exit(f"No federal_register*.json file in {BRONZE_DIR}. Run fetch_federal_register.py first.")
FILE = candidates[-1]  # newest file
print(f"Checking: {FILE}")

# 1. File must be valid JSON (a JSON array, {"results": [...]}, or one JSON object per line)
docs, bad_lines = [], 0
text = FILE.read_text(encoding="utf-8")
try:
    parsed = json.loads(text)
    docs = parsed.get("results", []) if isinstance(parsed, dict) else parsed
except json.JSONDecodeError:
    for line in text.splitlines():
        if line.strip():
            try:
                docs.append(json.loads(line))
            except json.JSONDecodeError:
                bad_lines += 1
df = pd.DataFrame(docs)
for col in ["document_number", "type", "publication_date", "agencies", "html_url"]:
    if col not in df:
        df[col] = None

problems, warnings = [], []
print(f"Records: {len(df)}   Unreadable lines: {bad_lines}")
if bad_lines:
    problems.append(f"{bad_lines} lines are not valid JSON")

# 2. Required fields present
for col in REQUIRED:
    missing = df[col].isna().sum() if col in df else len(df)
    if missing:
        problems.append(f"{missing} records missing '{col}'")

# 3. No duplicate document numbers
dupes = df["document_number"].duplicated().sum()
if dupes:
    problems.append(f"{dupes} duplicate document numbers")

# 4. Document types are what we asked for
print("\nDocument types:\n" + df["type"].value_counts().to_string())
unexpected = set(df["type"].dropna()) - {"Rule", "Proposed Rule"}
if unexpected:
    problems.append(f"Unexpected document types: {unexpected}")

# 5. Dates parse and fall inside our range
pub = pd.to_datetime(df["publication_date"], errors="coerce")
if pub.isna().sum():
    problems.append(f"{pub.isna().sum()} publication dates could not be parsed")
out_of_range = ((pub.dt.date < START_DATE) | (pub.dt.date > date.today())).sum()
if out_of_range:
    problems.append(f"{out_of_range} publication dates outside {START_DATE} to today")
print(f"\nPublication dates: {pub.min().date()} to {pub.max().date()}")

if "effective_on" in df:
    eff = pd.to_datetime(df["effective_on"], errors="coerce")
    early = (eff < pub).sum()
    if early:
        warnings.append(f"{early} rules take effect before publication (can be legitimate; spot-check a few)")

# 6. Every record belongs to one of our agencies
def has_our_agency(agencies):
    return any(a.get("slug") in OUR_AGENCIES for a in (agencies or []) if isinstance(a, dict))

wrong_agency = (~df["agencies"].apply(has_our_agency)).sum()
if wrong_agency:
    problems.append(f"{wrong_agency} records have none of our agencies")

# 7. ID coverage and format (your key slide finding)
def non_empty(col):
    return df[col].apply(lambda v: isinstance(v, list) and len(v) > 0) if col in df else pd.Series(False, index=df.index)

print("\nID coverage:")
for col in ["regulation_id_numbers", "docket_ids", "cfr_references"]:
    pct = 100 * non_empty(col).mean()
    print(f"  {col:24s} {pct:5.1f}%")

if "regulation_id_numbers" in df:
    all_rins = [r for lst in df["regulation_id_numbers"].dropna() for r in lst]
    bad_rins = [r for r in all_rins if not RIN_PATTERN.match(str(r))]
    if bad_rins:
        warnings.append(f"{len(bad_rins)} RINs in an unusual format, e.g. {bad_rins[:3]}")

# 8. Manual spot-check: open these and compare with the JSON
print("\nSpot-check these 5 against the website (title, date, type, agency):")
for _, row in df.sample(min(5, len(df)), random_state=random.randint(0, 9999)).iterrows():
    print(f"  {row['document_number']}  {row.get('html_url', '')}")

# Summary
print("\n" + "=" * 60)
for p in problems:
    print("FAIL  " + p)
for w in warnings:
    print("WARN  " + w)
if not problems:
    print("PASS  No blocking problems. Safe to load into Snowflake.")
sys.exit(1 if problems else 0)
