"""12 | Analyze Boston (city open data): official neighborhood boundaries and active food
establishment licenses. Dataset names change over time, so we search the portal for them.

No key needed. Matching each business to its neighborhood happens later, in Snowflake (silver).
Output: data/location/boston_neighborhoods_<date>.geojson, boston_food_licenses_<date>.csv
"""
import io

import pandas as pd

from common import TODAY, data_dir, http_get, rel, save_json

CKAN = "https://data.boston.gov/api/3/action/package_search"


def find_resource(query, formats):
    """Return (dataset title, download url) for the first resource in one of the formats."""
    response = http_get(CKAN, params={"q": query, "rows": 10})
    response.raise_for_status()
    for pkg in response.json()["result"]["results"]:
        for res in pkg.get("resources", []):
            if (res.get("format") or "").upper() in formats and res.get("url"):
                return pkg["title"], res["url"]
    raise SystemExit(f"No {formats} dataset found on Analyze Boston for '{query}'.")


def main():
    out_dir = data_dir("location")

    title, url = find_resource("boston neighborhood boundaries", {"GEOJSON"})
    response = http_get(url, timeout=120)
    response.raise_for_status()
    geo = response.json()
    geo_file = save_json(out_dir / f"boston_neighborhoods_{TODAY}.geojson", geo)
    print(f"{title}: {len(geo['features'])} neighborhoods -> {rel(geo_file)}")

    title, url = find_resource("food establishment licenses", {"CSV"})
    response = http_get(url, timeout=300)
    response.raise_for_status()
    food = pd.read_csv(io.StringIO(response.text), low_memory=False)
    food_file = out_dir / f"boston_food_licenses_{TODAY}.csv"
    food.to_csv(food_file, index=False)
    print(f"{title}: {len(food):,} licenses -> {rel(food_file)}")


if __name__ == "__main__":
    main()
