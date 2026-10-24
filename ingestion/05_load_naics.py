"""05 | NAICS: every US industry code (2022 edition), cleaned into one CSV.

Manual step first: download the "2-6 digit 2022 Code File" (XLSX) from census.gov/naics
and put it in data/naics/ (or leave it in your Downloads folder).
Output: data/naics/naics_2022.csv
"""
from pathlib import Path

import pandas as pd

from common import data_dir, rel

DEMO = {"72": "Restaurants and cafes", "23": "Construction", "44": "Retail", "45": "Retail"}


def find_source():
    for folder in [data_dir("naics"), Path.home() / "Downloads"]:
        files = sorted(folder.glob("*2-6*2022*Codes*.xlsx")) or sorted(folder.glob("*2022*Codes*.xlsx"))
        if files:
            return files[-1]
    raise SystemExit("NAICS file not found. Download the 2-6 digit 2022 Code File from census.gov/naics.")


def main():
    src = find_source()
    print(f"Reading {src.name}")
    df = pd.read_excel(src, dtype=str)
    code_col = next(c for c in df.columns if "code" in c.lower())
    title_col = next(c for c in df.columns if "title" in c.lower())
    df = df[[code_col, title_col]].rename(columns={code_col: "naics_code", title_col: "naics_title"})
    df = df.dropna(subset=["naics_code"])
    df["naics_code"] = df["naics_code"].str.strip()
    # Hidden line breaks become one space; trailing 'T' markers are removed
    df["naics_title"] = (df["naics_title"].str.replace(r"\s+", " ", regex=True)
                         .str.strip().str.rstrip("T").str.strip())
    df["level"] = df["naics_code"].str.replace(r"-.*", "", regex=True).str.len()
    df["sector"] = df["naics_code"].str[:2]
    df["demo_industry"] = df["sector"].map(DEMO)

    out_file = data_dir("naics") / "naics_2022.csv"
    df.to_csv(out_file, index=False)
    print(f"Saved {len(df):,} NAICS codes to {rel(out_file)}")
    print(df.groupby("level").size().rename("codes per level").to_string())


if __name__ == "__main__":
    main()
