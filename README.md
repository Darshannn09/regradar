# RegRadar

Tracking federal regulatory change so businesses don't have to.

RegRadar ingests federal regulatory data (Federal Register, eCFR, Regulations.gov,
Congress.gov) into Snowflake, models it with a medallion architecture
(Bronze raw, Silver Data Vault, Gold Kimball), and uses Snowflake Cortex and
LangGraph agents to tell a business which rules apply to it, explained in plain
English with citations.

Course: Generative AI & Data Engineering, Northeastern University

   ## Team
   | Name | Role |
   |---|---|
   | (Darshan) | Data Engineer - ingestion, Airflow, Bronze, Data Vault, dbt, Gold |
   | (Pranjal) | AI Engineer - Cortex, RAG, agents |
   | (Shreya) | App & DevOps Lead - Streamlit, MCP server, GitHub, governance |
## Repository layout
| Folder | What goes in it |
|---|---|
| `ingestion/` | Python scripts that pull data from the APIs |
| `sql/` | Snowflake setup and one-off SQL scripts |
| `airflow/dags/` | Airflow schedules for daily ingestion |
| `dbt/` | dbt project: Silver (Data Vault) and Gold (Kimball) models |
| `agents/` | LangGraph agents |
| `app/` | Streamlit app |
| `mcp/` | MCP server |
| `tests/` | Tests and the evaluation question set |
| `docs/` | Architecture diagrams and weekly update notes |

## Setup
1. `python -m venv venv`
2. Activate it: `venv\Scripts\activate` (Windows) or `source venv/bin/activate` (Mac)
3. `pip install -r requirements.txt`
4. Copy `.env.example` to `.env` and fill in your own keys. Never commit `.env`.

## Team rules
1. Never push directly to `main`. Every change goes through a pull request.
2. One branch per task, named `type/short-description`, for example `feature/fr-ingestion`.
3. Pull `main` before starting new work every day.
4. Each pull request needs one teammate's approval before merging.
5. Delete the branch after it is merged.
6. Never commit secrets, API keys, passwords, or data files.
7. Commit messages start with a verb: "Add ...", "Fix ...", "Update ...".
