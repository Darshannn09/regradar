"""
Pull a sample of Federal Register documents for our pilot agencies.
No API key needed.

Run:  python ingestion/fetch_federal_register.py
Output: data/bronze/federal_register_<date>.json  (one JSON record per line)
"""
import json
import time
from datetime import date
from pathlib import Path

import requests

BASE_URL = "https://www.federalregister.gov/api/v1/documents.json"

# Federal Register agency "slugs" for our pilot (food-service businesses)
AGENCIES = [
    "food-and-drug-administration",
    "food-safety-and-inspection-service",
    "occupational-safety-and-health-administration",
    "labor-department",
    "environmental-protection-agency",
]

DOC_TYPES = ["RULE", "PRORULE"]   # final rules and proposed rules
START_DATE = "2023-01-01"
PER_PAGE = 100
MAX_PAGES_PER_AGENCY = 3          # keep small for Week 1; raise later

FIELDS = [
    "document_number", "title", "type", "abstract", "action",
    "publication_date", "effective_on", "comments_close_on",
    "agencies", "regulation_id_numbers", "docket_ids", "cfr_references",
    "html_url", "raw_text_url", "full_text_xml_url", "significant",
]

out_dir = Path("data/bronze")
out_dir.mkdir(parents=True, exist_ok=True)
out_file = out_dir / f"federal_register_{date.today().isoformat()}.json"

total = 0
with out_file.open("w", encoding="utf-8") as f:
    for agency in AGENCIES:
        for page in range(1, MAX_PAGES_PER_AGENCY + 1):
            params = {
                "conditions[agencies][]": agency,
                "conditions[type][]": DOC_TYPES,
                "conditions[publication_date][gte]": START_DATE,
                "per_page": PER_PAGE,
                "page": page,
                "order": "newest",
                "fields[]": FIELDS,
            }
            resp = requests.get(BASE_URL, params=params, timeout=60)
            resp.raise_for_status()
            data = resp.json()

            if page == 1:
                print(f"{agency}: {data.get('count', 0)} matching documents in total")

            results = data.get("results", [])
            for doc in results:
                f.write(json.dumps(doc) + "\n")
            total += len(results)

            if not data.get("next_page_url"):
                break
            time.sleep(0.5)   # be polite to the API

print(f"\nSaved {total} documents to {out_file}")
