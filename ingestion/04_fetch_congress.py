"""04 | Congress.gov: the bill list for the 118th (2023-24) and 119th (2025-26) Congress.

Needs API_DATA_GOV_KEY (limit: 5,000 requests/hour).
Output: data/congress/bills_<date>.json
"""
import time

from common import TODAY, data_dir, env_key, http_get, rel, save_json

CONGRESSES = [118, 119]
LIMIT = 250
KEYWORDS = ["small business", "restaurant", "construction", "retail", "worker",
            "wage", "osha", "food", "employer", "tax credit"]


def main():
    key = env_key("API_DATA_GOV_KEY", hint="Free key: https://api.data.gov/signup")
    requests_used, all_bills = 0, []

    for congress in CONGRESSES:
        url = f"https://api.congress.gov/v3/bill/{congress}"
        offset, total = 0, None
        while total is None or offset < total:
            response = http_get(url, params={"api_key": key, "format": "json", "limit": LIMIT, "offset": offset})
            response.raise_for_status()
            requests_used += 1
            data = response.json()
            total = data.get("pagination", {}).get("count", 0)
            bills = data.get("bills", [])
            if not bills:
                break
            all_bills.extend(bills)
            offset += LIMIT
            if offset % 2500 == 0:
                print(f"  {congress}th Congress: {min(offset, total):,} of {total:,}")
            time.sleep(0.3)
        print(f"{congress}th Congress: {total:,} bills")

    unique = {f"{b.get('congress')}-{b.get('type')}-{b.get('number')}": b for b in all_bills}
    bills = list(unique.values())
    out_file = save_json(data_dir("congress") / f"bills_{TODAY}.json", bills)

    relevant = sum(1 for b in bills if any(k in (b.get("title") or "").lower() for k in KEYWORDS))
    print(f"\nSaved {len(bills):,} bills to {rel(out_file)}")
    print(f"Titles mentioning small-business topics: {relevant:,} ({100 * relevant / max(len(bills), 1):.1f}%)")
    print(f"API requests used: {requests_used}")


if __name__ == "__main__":
    main()
