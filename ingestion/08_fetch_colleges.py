"""08 | Colleges: every Massachusetts college with location and student counts (College Scorecard).

Needs API_DATA_GOV_KEY.
Output: data/location/colleges_ma_<date>.json
"""
import time

from common import TODAY, data_dir, env_key, http_get, rel, save_json

URL = "https://api.data.gov/ed/collegescorecard/v1/schools"
FIELDS = ",".join([
    "id", "school.name", "school.city", "school.zip",
    "location.lat", "location.lon",
    "latest.student.size", "latest.student.grad_students",
])


def main():
    key = env_key("API_DATA_GOV_KEY", hint="Free key: https://api.data.gov/signup")
    colleges, page = [], 0
    while True:
        response = http_get(URL, params={"api_key": key, "school.state": "MA", "fields": FIELDS,
                                         "per_page": 100, "page": page})
        response.raise_for_status()
        data = response.json()
        results = data.get("results", [])
        colleges.extend(results)
        if not results or len(colleges) >= data.get("metadata", {}).get("total", 0):
            break
        page += 1
        time.sleep(0.5)

    out_file = save_json(data_dir("location") / f"colleges_ma_{TODAY}.json", colleges, indent=2)
    students = sum((c.get("latest.student.size") or 0) + (c.get("latest.student.grad_students") or 0)
                   for c in colleges)
    print(f"Saved {len(colleges)} Massachusetts colleges ({students:,} students) to {rel(out_file)}")


if __name__ == "__main__":
    main()
