"""20 | Validate the newest Federal Register file on the laptop before loading it (free, no credits).

Checks: valid JSON, required fields, duplicates, document types, date range, agencies,
ID coverage, and RIN format. Prints 5 links to spot-check by hand.
Exit code 1 if a blocking problem is found, so a pipeline can stop on failure.
"""
import random
import re
import sys
from datetime import date

import pandas as pd

from common import newest, read_json, rel

START_DATE = date(2023, 1, 1)
REQUIRED = ["document_number", "title", "type", "publication_date", "agencies"]
RIN_PATTERN = re.compile(r"^\d{4}-[A-Z]{2}[0-9A-Z]{2}$")  # e.g. 0910-AI38


def main():
    file = newest("bronze", "federal_register*.json")
    if not file:
        sys.exit("No Federal Register file found. Run 01_fetch_federal_register.py first.")
    print(f"Checking {rel(file)}")
    df = pd.DataFrame(read_json(file))
    problems, warnings = [], []
    print(f"Records: {len(df):,}")

    for col in REQUIRED:
        missing = df[col].isna().sum() if col in df else len(df)
        if missing:
            problems.append(f"{missing} records missing '{col}'")

    dupes = df["document_number"].duplicated().sum()
    if dupes:
        problems.append(f"{dupes} duplicate document numbers")

    print("\nDocument types:\n" + df["type"].value_counts().to_string())
    unexpected = set(df["type"].dropna()) - {"Rule", "Proposed Rule"}
    if unexpected:
        problems.append(f"Unexpected document types: {unexpected}")

    pub = pd.to_datetime(df["publication_date"], errors="coerce")
    if pub.isna().sum():
        problems.append(f"{pub.isna().sum()} publication dates could not be parsed")
    out_of_range = ((pub.dt.date < START_DATE) | (pub.dt.date > date.today())).sum()
    if out_of_range:
        problems.append(f"{out_of_range} publication dates outside {START_DATE} to today")
    print(f"\nPublication dates: {pub.min().date()} to {pub.max().date()}")

    if "effective_on" in df:
        early = (pd.to_datetime(df["effective_on"], errors="coerce") < pub).sum()
        if early:
            warnings.append(f"{early} rules take effect before publication (can be legitimate)")

    no_agency = (~df["agencies"].apply(lambda a: bool(a) and isinstance(a, list))).sum()
    if no_agency:
        warnings.append(f"{no_agency} records have no agency listed")
    top = (df["agencies"].explode().dropna()
           .apply(lambda a: a.get("name") if isinstance(a, dict) else None).value_counts().head(10))
    print("\nTop 10 agencies:\n" + top.to_string())

    print("\nID coverage:")
    for col in ["regulation_id_numbers", "docket_ids", "cfr_references"]:
        pct = 100 * df[col].apply(lambda v: isinstance(v, list) and len(v) > 0).mean() if col in df else 0
        print(f"  {col:24s} {pct:5.1f}%")

    rins = [r for lst in df.get("regulation_id_numbers", pd.Series(dtype=object)).dropna() for r in lst]
    bad_rins = [r for r in rins if not RIN_PATTERN.match(str(r))]
    if bad_rins:
        warnings.append(f"{len(bad_rins)} RINs in an unusual format, e.g. {bad_rins[:3]}")

    print("\nSpot-check these 5 on federalregister.gov:")
    for _, row in df.sample(min(5, len(df)), random_state=random.randint(0, 9999)).iterrows():
        print(f"  {row['document_number']}  {row.get('html_url', '')}")

    print("\n" + "=" * 60)
    for p in problems:
        print("FAIL  " + p)
    for w in warnings:
        print("WARN  " + w)
    if not problems:
        print("PASS  No blocking problems. Safe to load into Snowflake.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
