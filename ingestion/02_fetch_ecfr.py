"""02 | eCFR: current full text and version history for the CFR parts RegRadar needs.

No API key needed.
Output: data/ecfr/title<T>_part<P>_versions.json and title<T>_part<P>_<date>.xml
"""
import time

from common import data_dir, http_get, rel, save_json

BASE = "https://www.ecfr.gov/api/versioner/v1"
PARTS = [  # (title, part, what it covers)
    (21, "117", "FDA food safety practices"),
    (21, "101", "Food labeling"),
    (29, "1910", "OSHA general workplace safety"),
    (29, "1926", "OSHA construction safety"),
    (29, "516", "Wage and hour recordkeeping"),
    (40, "82", "EPA refrigerant rules"),
]


def get(url, **params):
    response = http_get(url, params=params or None, timeout=120)
    response.raise_for_status()
    return response


def main():
    out_dir = data_dir("ecfr")

    # Each title has its own "up to date as of" date; full text must use that date or earlier
    titles = get(f"{BASE}/titles.json").json()["titles"]
    as_of = {t["number"]: t["up_to_date_as_of"] for t in titles}
    save_json(out_dir / "titles.json", titles, indent=2)

    for title, part, label in PARTS:
        version_date = as_of[title]
        name = f"title{title}_part{part}"

        versions = get(f"{BASE}/versions/title-{title}.json", part=part).json()
        save_json(out_dir / f"{name}_versions.json", versions, indent=2)

        xml = get(f"{BASE}/full/{version_date}/title-{title}.xml", part=part).text
        (out_dir / f"{name}_{version_date}.xml").write_text(xml, encoding="utf-8")

        print(f"{title} CFR {part:<5} {label:<32} {len(versions.get('content_versions', [])):>5} versions, "
              f"text as of {version_date} ({len(xml) / 1_000_000:.1f} MB)")
        time.sleep(1)

    print(f"\nSaved to {rel(out_dir)}")


if __name__ == "__main__":
    main()
