"""07 | Massachusetts bills from LegiScan, for sessions starting 2023 or later.

Needs LEGISCAN_API_KEY (free tier: 10,000 queries/month). Uses about 3 queries per run.
Data is licensed CC BY 4.0: credit LegiScan wherever it is shown.
Status: waiting for the API key.
Output: data/ma_bills/ma_bills_<date>.json
"""
import time

from common import TODAY, data_dir, env_key, http_get, rel, save_json

BASE = "https://api.legiscan.com/"
KEYWORDS = ["small business", "restaurant", "construction", "retail", "minimum wage",
            "sick time", "employer", "food", "license", "tax"]


def call(key, op, **params):
    response = http_get(BASE, params={"key": key, "op": op, **params})
    response.raise_for_status()
    data = response.json()
    if data.get("status") != "OK":
        raise SystemExit(f"LegiScan error: {data}")
    return data


def main():
    key = env_key("LEGISCAN_API_KEY", hint="Request a free key at legiscan.com.")
    sessions = [s for s in call(key, "getSessionList", state="MA")["sessions"]
                if int(s.get("year_start", 0)) >= 2023]

    bills = []
    for s in sessions:
        master = call(key, "getMasterList", id=s["session_id"])["masterlist"]
        session_bills = [v for k, v in master.items() if k != "session"]
        for b in session_bills:
            b.update({"session_id": s["session_id"], "session_name": s["session_name"]})
        bills.extend(session_bills)
        print(f"{s['session_name']}: {len(session_bills):,} bills")
        time.sleep(1)

    out_file = save_json(data_dir("ma_bills") / f"ma_bills_{TODAY}.json", bills)
    relevant = sum(1 for b in bills
                   if any(k in f"{b.get('title', '')} {b.get('description', '')}".lower() for k in KEYWORDS))
    print(f"\nSaved {len(bills):,} Massachusetts bills to {rel(out_file)}")
    print(f"Mentioning small-business topics: {relevant:,}")


if __name__ == "__main__":
    main()
