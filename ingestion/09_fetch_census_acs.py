"""09 | Census ACS 5-year: residents, ages 18-34, income, and median age for every
census tract in Suffolk County (Boston, Chelsea, Revere, Winthrop), plus tract center points.

Needs CENSUS_API_KEY (free: https://api.census.gov/data/key_signup.html).
Output: data/location/census_acs_suffolk_<acs year>_<date>.csv
"""
import io
import zipfile

import pandas as pd

from common import TODAY, data_dir, env_key, http_get, rel

STATE, COUNTY = "25", "025"  # Massachusetts, Suffolk County
AGE_18_34 = [f"B01001_{n:03d}E" for n in list(range(7, 13)) + list(range(31, 37))]
VARS = ["NAME", "B01003_001E", "B19013_001E", "B01002_001E"] + AGE_18_34
GAZETTEER = "https://www2.census.gov/geo/docs/maps-data/data/gazetteer"


def fetch_acs(key):
    """Try the newest ACS year first; the Census answers with an error page if a year isn't out yet."""
    for year in [2024, 2023, 2022]:
        params = {"get": ",".join(VARS), "for": "tract:*", "in": f"state:{STATE} county:{COUNTY}"}
        if key:
            params["key"] = key
        response = http_get(f"https://api.census.gov/data/{year}/acs/acs5", params=params)
        try:
            rows = response.json()
        except ValueError:
            print(f"  ACS {year}: not available (HTTP {response.status_code}), trying the previous year")
            continue
        return pd.DataFrame(rows[1:], columns=rows[0]), year
    raise SystemExit("Could not download ACS data.")


def fetch_tract_centers():
    """Tract center points from the Gazetteer file. File names vary by year, so try several."""
    for year in [2024, 2023, 2022, 2020]:
        for name in [f"{year}_gaz_tracts_{STATE}.txt", f"{year}_Gaz_tracts_{STATE}.txt",
                     f"{year}_Gaz_tracts_national.zip"]:
            response = http_get(f"{GAZETTEER}/{year}_Gazetteer/{name}", timeout=120)
            if not response.ok:
                continue
            if name.endswith(".zip"):
                with zipfile.ZipFile(io.BytesIO(response.content)) as z:
                    text = z.read(z.namelist()[0]).decode("utf-8-sig", errors="replace")
            else:
                text = response.content.decode("utf-8-sig", errors="replace")
            if "GEOID" not in text[:500]:
                continue
            gaz = pd.read_csv(io.StringIO(text), sep="\t", dtype={"GEOID": str})
            gaz.columns = [c.strip() for c in gaz.columns]
            gaz = gaz[gaz["GEOID"].str.startswith(STATE + COUNTY)]
            print(f"  tract centers: {name} ({len(gaz)} Suffolk County tracts)")
            return gaz.rename(columns={"GEOID": "geoid", "INTPTLAT": "lat", "INTPTLONG": "lon"})
    raise SystemExit("Could not download tract center points.")


def main():
    key = env_key("CENSUS_API_KEY", required=False)
    acs, acs_year = fetch_acs(key)
    for col in VARS[1:]:
        acs[col] = pd.to_numeric(acs[col], errors="coerce")
    acs["geoid"] = acs["state"] + acs["county"] + acs["tract"]
    acs["population"] = acs["B01003_001E"]
    acs["median_income"] = acs["B19013_001E"].where(acs["B19013_001E"] > 0)  # negative = missing
    acs["median_age"] = acs["B01002_001E"].where(acs["B01002_001E"] > 0)
    acs["age_18_34"] = acs[AGE_18_34].sum(axis=1)

    tracts = acs.merge(fetch_tract_centers()[["geoid", "lat", "lon"]], on="geoid", how="left")
    tracts = tracts[["geoid", "NAME", "population", "age_18_34", "median_income", "median_age", "lat", "lon"]]

    out_file = data_dir("location") / f"census_acs_suffolk_{acs_year}_{TODAY}.csv"
    tracts.to_csv(out_file, index=False)
    print(f"ACS {acs_year} 5-year: saved {len(tracts)} tracts to {rel(out_file)}")
    print(f"Tracts missing a center point: {tracts['lat'].isna().sum()}")


if __name__ == "__main__":
    main()
