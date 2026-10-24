"""01 | Federal Register: every final and proposed rule, all agencies, since January 2023.

The API limits how many results one query can page through, so we fetch month by month.
Duplicates are removed by document_number. No API key needed.
Output: data/bronze/federal_register_all_<date>.json
"""
import time
from datetime import date, timedelta

from common import TODAY, data_dir, http_get, rel, save_json

BASE_URL = "https://www.federalregister.gov/api/v1/documents.json"
START = date(2023, 1, 1)
PER_PAGE = 1000
FIELDS = [
    "document_number", "title", "type", "abstract", "action",
    "publication_date", "effective_on", "comments_close_on",
    "agencies", "topics", "docket_ids", "regulation_id_numbers",
    "cfr_references", "significant", "html_url", "raw_text_url",
]


def month_ranges(start, end):
    """Yield (first day, last day) for every month from start to end."""
    y, m = start.year, start.month
    while date(y, m, 1) <= end:
        ny, nm = (y + 1, 1) if m == 12 else (y, m + 1)
        yield date(y, m, 1), min(date(ny, nm, 1) - timedelta(days=1), end)
        y, m = ny, nm


def fetch_month(first, last):
    docs, page = [], 1
    while True:
        params = [
            ("conditions[type][]", "RULE"),
            ("conditions[type][]", "PRORULE"),
            ("conditions[publication_date][gte]", first.isoformat()),
            ("conditions[publication_date][lte]", last.isoformat()),
            ("per_page", PER_PAGE),
            ("page", page),
            ("order", "oldest"),
        ] + [("fields[]", f) for f in FIELDS]
        response = http_get(BASE_URL, params=params)
        response.raise_for_status()
        data = response.json()
        docs.extend(data.get("results", []))
        if page >= data.get("total_pages", 1):
            return docs
        page += 1
        time.sleep(0.5)


def main():
    seen, documents = set(), []
    for first, last in month_ranges(START, date.today()):
        new = 0
        for doc in fetch_month(first, last):
            if doc["document_number"] not in seen:
                seen.add(doc["document_number"])
                documents.append(doc)
                new += 1
        print(f"{first:%Y-%m}: {new:>5} documents")
        time.sleep(0.5)

    out_file = save_json(data_dir("bronze") / f"federal_register_all_{TODAY}.json", documents)
    rules = sum(1 for d in documents if d.get("type") == "Rule")
    print(f"\nSaved {len(documents):,} unique documents ({rules:,} final, "
          f"{len(documents) - rules:,} proposed) to {rel(out_file)}")


if __name__ == "__main__":
    main()
