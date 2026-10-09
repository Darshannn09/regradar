"""
Quick test of the other three sources. Saves a small sample from each
into data/samples/ so the team can study the fields.

Needs API_DATA_GOV_KEY in your .env file (free from https://api.data.gov/signup/).
Run:  python ingestion/test_other_apis.py
"""
import json
import os
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()
KEY = os.getenv("API_DATA_GOV_KEY")
if not KEY:
    raise SystemExit("Add API_DATA_GOV_KEY to your .env file first.")

out = Path("data/samples")
out.mkdir(parents=True, exist_ok=True)


def save(name, payload):
    path = out / f"{name}.json"
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"  saved -> {path}")


# 1. Regulations.gov: FDA documents (rules, proposed rules, notices)
print("Regulations.gov ...")
r = requests.get(
    "https://api.regulations.gov/v4/documents",
    params={"filter[agencyId]": "FDA", "page[size]": 25, "api_key": KEY},
    timeout=60,
)
r.raise_for_status()
reg = r.json()
print(f"  total FDA documents reported: {reg.get('meta', {}).get('totalElements')}")
print(f"  rate limit remaining this hour: {r.headers.get('X-RateLimit-Remaining')}")
save("regulations_gov_fda_documents", reg)

# 2. Congress.gov: most recently updated bills
print("Congress.gov ...")
c = requests.get(
    "https://api.congress.gov/v3/bill",
    params={"api_key": KEY, "format": "json", "limit": 25},
    timeout=60,
)
c.raise_for_status()
cong = c.json()
print(f"  bills returned: {len(cong.get('bills', []))}")
save("congress_recent_bills", cong)

# 3. eCFR: version history for 21 CFR Part 117 (FDA food safety rules). No key needed.
print("eCFR ...")
e = requests.get(
    "https://www.ecfr.gov/api/versioner/v1/versions/title-21.json",
    params={"part": "117"},
    timeout=60,
)
e.raise_for_status()
ecfr = e.json()
print(f"  versions of 21 CFR 117 found: {len(ecfr.get('content_versions', []))}")
save("ecfr_title21_part117_versions", ecfr)

print("\nDone. Open data/samples/ and note the key fields and IDs for each source.")
