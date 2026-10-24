"""10 | Census County Business Patterns: number of businesses (with employees) by ZIP code
and industry, for Suffolk County ZIP codes. The Census publishes this about two years behind.

Needs CENSUS_API_KEY.
Output: data/location/business_patterns_boston_<data year>_<date>.csv
"""
import pandas as pd

from common import TODAY, data_dir, env_key, http_get, rel

ZIPS = ["02108", "02109", "02110", "02111", "02113", "02114", "02115", "02116", "02118",
        "02119", "02120", "02121", "02122", "02124", "02125", "02126", "02127", "02128",
        "02129", "02130", "02131", "02132", "02134", "02135", "02136", "02163", "02199",
        "02210", "02215", "02150", "02151", "02152"]
INDUSTRIES = {
    "722515": "Cafes and snack bars",
    "722511": "Full-service restaurants",
    "7225": "All restaurants and eating places",
    "44-45": "Retail",
    "23": "Construction",
}


def fetch(key):
    """Try the newest year and NAICS edition first; fall back until one works."""
    for year in [2024, 2023, 2022]:
        for naics_var in ["NAICS2022", "NAICS2017"]:
            frames = []
            for code, label in INDUSTRIES.items():
                params = {"get": f"ESTAB,{naics_var}_LABEL", "for": f"zip code:{','.join(ZIPS)}", naics_var: code}
                if key:
                    params["key"] = key
                response = http_get(f"https://api.census.gov/data/{year}/cbp", params=params)
                try:
                    data = response.json()
                except ValueError:
                    frames = None
                    break
                df = pd.DataFrame(data[1:], columns=data[0])
                df["naics_code"], df["industry"] = code, label
                frames.append(df)
            if frames:
                return pd.concat(frames, ignore_index=True), year, naics_var
            print(f"  CBP {year} with {naics_var}: not available, trying next")
    raise SystemExit("Could not download County Business Patterns data.")


def main():
    cbp, year, naics_var = fetch(env_key("CENSUS_API_KEY", required=False))
    cbp = cbp.rename(columns={"zip code": "zip", "ESTAB": "establishments"})
    cbp["establishments"] = pd.to_numeric(cbp["establishments"], errors="coerce").fillna(0).astype(int)
    cbp = cbp[["zip", "naics_code", "industry", "establishments"]]

    out_file = data_dir("location") / f"business_patterns_boston_{year}_{TODAY}.csv"
    cbp.to_csv(out_file, index=False)
    print(f"CBP {year} ({naics_var}): saved {len(cbp)} ZIP-industry counts to {rel(out_file)}")
    print(cbp.groupby("industry")["establishments"].sum().to_string())


if __name__ == "__main__":
    main()
