"""11 | MBTA: every rapid transit station (subway and light rail) with its location and lines.

No key needed; the API allows about 20 requests per minute without one.
Output: data/location/mbta_stations_<date>.json
"""
import time

from common import TODAY, data_dir, http_get, rel, save_json

API = "https://api-v3.mbta.com"
ROUTES = ["Red", "Orange", "Blue", "Green-B", "Green-C", "Green-D", "Green-E", "Mattapan"]


def main():
    stations = {}
    for route in ROUTES:
        response = http_get(f"{API}/stops", params={"filter[route]": route})
        response.raise_for_status()
        stops = response.json().get("data", [])
        for s in stops:
            a = s["attributes"]
            station = stations.setdefault(s["id"], {
                "station_id": s["id"], "name": a.get("name"), "municipality": a.get("municipality"),
                "lat": a.get("latitude"), "lon": a.get("longitude"), "lines": [],
            })
            station["lines"].append(route)
        print(f"{route:<9} {len(stops):>3} stations")
        time.sleep(3)

    out_file = save_json(data_dir("location") / f"mbta_stations_{TODAY}.json", list(stations.values()), indent=2)
    print(f"\nSaved {len(stations)} unique stations to {rel(out_file)}")


if __name__ == "__main__":
    main()
