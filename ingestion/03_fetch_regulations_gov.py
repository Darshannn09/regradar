"""03 | Regulations.gov: proposed and final rule documents for small-business agencies.

Each document carries its docket ID, comment dates, and Federal Register number (frDocNum),
which links it to the Federal Register data. Needs API_DATA_GOV_KEY (limit: 1,000 requests/hour).
Output: data/regulations_gov/documents_<date>.json
"""
import time
from datetime import date

from common import TODAY, data_dir, env_key, http_get, rel, save_json

BASE = "https://api.regulations.gov/v4/documents"
AGENCIES = ["OSHA", "WHD", "EBSA", "FDA", "FSIS", "EPA", "FTC", "IRS", "SBA", "CPSC"]
DOC_TYPES = ["Proposed Rule", "Rule"]
PAGE_SIZE = 250


def main():
    key = env_key("API_DATA_GOV_KEY", hint="Free key: https://api.data.gov/signup")
    requests_used = 0
    documents, seen = [], set()

    for agency in AGENCIES:
        agency_count = 0
        for year in range(2023, date.today().year + 1):
            for doc_type in DOC_TYPES:
                page = 1
                while True:
                    response = http_get(BASE, headers={"X-Api-Key": key}, params={
                        "filter[agencyId]": agency,
                        "filter[documentType]": doc_type,
                        "filter[postedDate][ge]": f"{year}-01-01",
                        "filter[postedDate][le]": f"{year}-12-31",
                        "page[size]": PAGE_SIZE,
                        "page[number]": page,
                    })
                    response.raise_for_status()
                    requests_used += 1
                    if int(response.headers.get("X-RateLimit-Remaining", "1000")) < 20:
                        print("    close to the hourly limit, pausing 5 minutes...")
                        time.sleep(300)

                    data = response.json()
                    for item in data.get("data", []):
                        if item["id"] not in seen:
                            seen.add(item["id"])
                            documents.append({"id": item["id"], **item.get("attributes", {})})
                            agency_count += 1
                    if not data.get("meta", {}).get("hasNextPage"):
                        break
                    page += 1
                    time.sleep(0.5)
        print(f"{agency:<5} {agency_count:>5} documents")

    out_file = save_json(data_dir("regulations_gov") / f"documents_{TODAY}.json", documents)
    open_now = sum(1 for d in documents if d.get("openForComment"))
    with_fr = sum(1 for d in documents if d.get("frDocNum"))
    print(f"\nSaved {len(documents):,} documents to {rel(out_file)}")
    print(f"Open for comment now: {open_now}")
    print(f"With a Federal Register number: {with_fr:,} ({100 * with_fr / max(len(documents), 1):.1f}%)")
    print(f"API requests used: {requests_used}")


if __name__ == "__main__":
    main()
