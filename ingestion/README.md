# Ingestion

Python scripts that collect every source and load it into Snowflake **bronze**.
Run them from the repo root, in numbered order, with the virtual environment active.
Shared code (paths, keys, retries) lives in `common.py`.

| Script | Source | Key needed | Output in `data/` |
|---|---|---|---|
| `01_fetch_federal_register.py` | Federal Register, all agencies, 2023 to today | none | `bronze/` |
| `02_fetch_ecfr.py` | eCFR text and version history (6 CFR parts) | none | `ecfr/` |
| `03_fetch_regulations_gov.py` | Regulations.gov rule documents (10 agencies) | `API_DATA_GOV_KEY` | `regulations_gov/` |
| `04_fetch_congress.py` | Congress.gov bills (118th, 119th) | `API_DATA_GOV_KEY` | `congress/` |
| `05_load_naics.py` | NAICS 2022 codes (manual XLSX download first) | none | `naics/` |
| `06_extract_ma_regulations.py` | Massachusetts CMR PDFs (manual download first) | none | `ma_regulations/` |
| `07_fetch_ma_bills.py` | Massachusetts bills from LegiScan (pending key) | `LEGISCAN_API_KEY` | `ma_bills/` |
| `08_fetch_colleges.py` | College Scorecard, Massachusetts colleges | `API_DATA_GOV_KEY` | `location/` |
| `09_fetch_census_acs.py` | Census ACS 5-year, Suffolk County tracts | `CENSUS_API_KEY` | `location/` |
| `10_fetch_business_patterns.py` | Census County Business Patterns by ZIP | `CENSUS_API_KEY` | `location/` |
| `11_fetch_mbta_stations.py` | MBTA rapid transit stations | none | `location/` |
| `12_fetch_analyze_boston.py` | Boston neighborhoods and food licenses | none | `location/` |
| `20_validate_federal_register.py` | Local checks before loading (free) | none | prints PASS/FAIL |
| `30_load_bronze.py` | Loads everything into `REGRADAR_DB.BRONZE` | Snowflake | 13+ bronze tables |

Run everything in order with `scripts\run_ingestion.ps1`. The `data/` folder is not committed to GitHub.
