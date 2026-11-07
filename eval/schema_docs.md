
# RegRadar gold schema: notes for writing SQL

Database REGRADAR_DB, schema GOLD, Snowflake SQL. Always use full names, for example REGRADAR_DB.GOLD.FACT_RULE.

## Facts and their grain
- FACT_RULE: one row per regulation document (federal rules, proposed rules, and Massachusetts regulations). Join to DIM_RULE on RULE_KEY for its title and DOCUMENT_TYPE.
- FACT_CFR_CHANGE: one row per change to one CFR section. Join to DIM_CFR_PART on CFR_PART_KEY.
- FACT_BILL: one row per bill.
- FACT_NEIGHBORHOOD_PROFILE: one row per Boston neighborhood (residents, residents aged 18-34, colleges, students, T stations, food establishments). Join to DIM_NEIGHBORHOOD on NEIGHBORHOOD_KEY.
- FACT_BUSINESS_COUNT: one row per ZIP code x industry x year (Census counts). Join to DIM_ZIP and DIM_INDUSTRY.
- FACT_ESTABLISHMENT: one row per licensed food business. Count rows to count businesses.

## Dates (role-playing)
- All date keys are NUMBER in YYYYMMDD form and join to DIM_DATE.DATE_KEY. Filter by year with DIM_DATE.YEAR.
- FACT_RULE has four different dates. Use the one the question asks about:
  PUBLICATION_DATE_KEY (published), EFFECTIVE_DATE_KEY (takes effect),
  COMMENT_START_DATE_KEY, COMMENT_END_DATE_KEY (comment deadline).
- "Published in <year>" means PUBLICATION_DATE_KEY. "Took effect in <year>" means EFFECTIVE_DATE_KEY.

## Unknown values
- Missing keys are never NULL. They are -1 (the "Unknown" row in every dimension).
- "No effective date" means EFFECTIVE_DATE_KEY = -1.
- "Outside Boston neighborhoods" means NEIGHBORHOOD_KEY = -1.

## Industries and the bridge table
- Rules link to industries only through BRIDGE_RULE_INDUSTRY (RULE_KEY, INDUSTRY_KEY). A rule can have several industries.
- When counting rules through the bridge, use COUNT(DISTINCT rule_key) so a rule is never counted twice.
- Industry codes are NAICS codes stored as text in DIM_INDUSTRY.NAICS_CODE. Codes used in this project:
  '722' food services and drinking places (restaurants), '7225' restaurants and other eating places,
  '722515' cafes and snack bars, '722511' full-service restaurants, '23' construction, '44-45' retail.

## Rule types
- DIM_RULE.DOCUMENT_TYPE is 'Rule' (a final rule), 'Proposed Rule', or 'State Regulation'.

## Agencies
- FACT_RULE.PRIMARY_AGENCY_KEY joins to DIM_AGENCY.AGENCY_KEY (the first-listed agency).
- FACT_RULE.AGENCY_COUNT is the number of agencies on the rule.

## Rule text history (SCD Type 2)
- DIM_CFR_PART has one row per version of a CFR part, with VALID_FROM, VALID_TO, IS_CURRENT.
- CFR_CITATION looks like '29 CFR 1926'. Count versions by counting rows for a citation.
- The version in force on a date is the row where that date is BETWEEN VALID_FROM AND VALID_TO.

## Flags and measures
- Boolean columns can be used directly: WHERE is_open_for_comment, WHERE is_substantive, WHERE is_small_business_relevant.
- COMMENT_PERIOD_DAYS can be NULL; ignore NULLs when averaging.
- MEDIAN_HOUSEHOLD_INCOME is non-additive: never SUM it.

## Writing correct SQL for this schema
- Many tables share key names (RULE_KEY, INDUSTRY_KEY, DATE_KEY). When joining, give every table an alias and prefix every column with it, for example COUNT(DISTINCT f.rule_key).
- NAICS_CODE is text, not a number. Always compare it to quoted strings, for example naics_code IN ('722', '44-45').
- FACT_BUSINESS_COUNT already holds counts: one row per ZIP code, industry, and year. The number of businesses is the ESTABLISHMENTS column. Do not count rows. Filter to one industry code, because codes overlap ('7225' includes '722515').
