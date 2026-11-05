"""Text-to-SQL evaluation on the RegRadar gold star schema, inspired by Spider 2.0 (Lei et al., ICLR 2025).

Compares two ways of asking a Snowflake Cortex LLM to write SQL for 22 questions with known answers:

  BEFORE ("baseline"):  question + table and column names only, one attempt
  AFTER  ("spider2"):   adds what Spider 2.0 found models need on real warehouses:
                        1. documentation of the schema (grain, date roles, unknown member, bridge rules)
                        2. sample values from key columns (codes, categories, names)
                        3. an execution-feedback loop: run the SQL, show the model any error or an
                           empty result, and let it try again (up to 3 attempts), like Spider-Agent

Metric: execution accuracy, as in Spider 2.0: the predicted query's result must contain the gold
query's result (each gold column must match a predicted column, row order ignored; numbers compared
with a small tolerance). Also reports valid-SQL rate, latency, prompt size, and attempts.

Run from the repo root (venv active):
    python eval/text2sql_eval.py                  # both conditions, all questions
    python eval/text2sql_eval.py --limit 5        # quick test
    python eval/text2sql_eval.py --model mistral-large2
    python eval/text2sql_eval.py --conditions baseline,docs_only,spider2   # ablation: which technique helps?
Results: printed summary, eval/results/<run>.csv, and table REGRADAR_DB.APP.TEXT2SQL_EVAL.
"""
import argparse
import csv
import datetime as dt
import json
import os
import re
import sys
import time
from decimal import Decimal
from pathlib import Path

import snowflake.connector

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ingestion"))
from common import env_key  # noqa: E402  (also loads .env)

EVAL_DIR = Path(__file__).resolve().parent
MODELS = ["claude-3-5-sonnet", "mistral-large2", "llama3.1-70b", "snowflake-arctic"]
MAX_ATTEMPTS = 3


# ---------------------------------------------------------------- Snowflake
def connect():
    params = dict(account=env_key("SNOWFLAKE_ACCOUNT"), user=env_key("SNOWFLAKE_USER"),
                  password=env_key("SNOWFLAKE_PASSWORD"), database="REGRADAR_DB", schema="GOLD")
    if os.getenv("SNOWFLAKE_ROLE"):
        params["role"] = os.getenv("SNOWFLAKE_ROLE")
    conn = snowflake.connector.connect(**params)
    cur = conn.cursor()
    cur.execute(f"USE WAREHOUSE {os.getenv('SNOWFLAKE_WAREHOUSE') or 'REGRADAR_WH'}")
    cur.execute("ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 60")
    return conn, cur


def pick_model(cur, wanted):
    for m in ([wanted] if wanted else []) + MODELS:
        try:
            cur.execute("SELECT SNOWFLAKE.CORTEX.COMPLETE(%s, 'Reply with the word OK.')", (m,))
            cur.fetchone()
            return m
        except snowflake.connector.errors.Error:
            print(f"  model {m} not available, trying the next one")
    raise SystemExit("No Cortex model available. Check region or enable cross-region inference.")


def complete(cur, model, prompt):
    start = time.time()
    cur.execute("SELECT SNOWFLAKE.CORTEX.COMPLETE(%s, %s)", (model, prompt))
    return cur.fetchone()[0], time.time() - start


def run_sql(cur, sql):
    """Run a read-only query. Returns (rows, error)."""
    if not re.match(r"^\s*(SELECT|WITH)\b", sql, re.I):
        return None, "Only SELECT queries are allowed."
    try:
        cur.execute(sql)
        return cur.fetchmany(1000), None
    except snowflake.connector.errors.Error as e:
        return None, str(e).splitlines()[0][:400]


# ---------------------------------------------------------------- context for the model
def schema_listing(cur):
    """Table and column names with types: what a naive text-to-SQL prompt usually gets."""
    cur.execute("""SELECT table_name, LISTAGG(column_name || ' ' || data_type, ', ')
                          WITHIN GROUP (ORDER BY ordinal_position)
                   FROM REGRADAR_DB.INFORMATION_SCHEMA.COLUMNS
                   WHERE table_schema = 'GOLD' GROUP BY table_name ORDER BY table_name""")
    return "\n".join(f"REGRADAR_DB.GOLD.{t}({cols})" for t, cols in cur.fetchall())


def sample_values(cur):
    """Real values for columns the model must filter on (Spider 2.0: models must inspect the data)."""
    probes = {
        "DIM_RULE.DOCUMENT_TYPE": "SELECT DISTINCT document_type FROM REGRADAR_DB.GOLD.DIM_RULE",
        "DIM_INDUSTRY (code: title)": "SELECT naics_code || ': ' || naics_title FROM REGRADAR_DB.GOLD.DIM_INDUSTRY "
                                      "WHERE naics_code IN ('722','7225','722515','722511','23','44-45')",
        "DIM_CFR_PART.CFR_CITATION (tracked parts)": "SELECT DISTINCT cfr_citation || ' = ' || part_name "
                                      "FROM REGRADAR_DB.GOLD.DIM_CFR_PART WHERE part_name IS NOT NULL",
        "DIM_NEIGHBORHOOD.NEIGHBORHOOD_NAME": "SELECT neighborhood_name FROM REGRADAR_DB.GOLD.DIM_NEIGHBORHOOD "
                                      "WHERE neighborhood_key <> -1 ORDER BY 1",
        "DIM_AGENCY.AGENCY_NAME (examples)": "SELECT agency_name FROM REGRADAR_DB.GOLD.DIM_AGENCY "
                                      "WHERE agency_key <> -1 ORDER BY agency_name LIMIT 15",
    }
    lines = []
    for label, q in probes.items():
        cur.execute(q)
        lines.append(f"{label}: " + "; ".join(str(r[0]) for r in cur.fetchall()))
    return "\n".join(lines)


def baseline_prompt(schema, question):
    return (f"You are an expert in Snowflake SQL. Using these tables:\n{schema}\n\n"
            f"Write one SQL query that answers: {question}\n"
            "Return only the SQL query.")


def spider2_prompt(schema, docs, samples, question, history):
    p = (f"You are an expert in Snowflake SQL working on a Kimball star schema.\n\n"
         f"TABLES:\n{schema}\n\nDOCUMENTATION:\n{docs}\n\nSAMPLE VALUES:\n{samples}\n\n"
         f"QUESTION: {question}\n")
    for i, (sql, feedback) in enumerate(history, 1):
        p += f"\nATTEMPT {i}:\n{sql}\nRESULT: {feedback}\n"
    if history:
        p += "\nFix the query using the result above.\n"
    return p + "Return only one SQL query, with no explanation."


def extract_sql(text):
    m = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    sql = m.group(1) if m else text
    m = re.search(r"\b(WITH|SELECT)\b.*", sql, re.S | re.I)
    sql = m.group(0) if m else sql
    return sql.strip().split(";")[0].strip()


# ---------------------------------------------------------------- scoring (Spider 2.0 style)
def norm(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float, Decimal)):
        return round(float(v), 2)
    if isinstance(v, (dt.date, dt.datetime)):
        return v.isoformat()[:10]
    return str(v).strip().lower()


def same_column(a, b):
    if len(a) != len(b):
        return False
    key = lambda x: (x is None, str(type(x)), x if x is not None else 0)
    for x, y in zip(sorted(a, key=key), sorted(b, key=key)):
        if isinstance(x, float) and isinstance(y, float):
            if abs(x - y) > max(0.06, abs(x) * 1e-4):
                return False
        elif x != y:
            return False
    return True


def is_correct(gold_rows, pred_rows):
    """Each gold column must match some predicted column; extra predicted columns are allowed."""
    if pred_rows is None or len(gold_rows) != len(pred_rows):
        return False
    gold_cols = list(zip(*[[norm(v) for v in r] for r in gold_rows])) or [()]
    pred_cols = list(zip(*[[norm(v) for v in r] for r in pred_rows])) or [()]
    return all(any(same_column(list(g), list(p)) for p in pred_cols) for g in gold_cols)


# ---------------------------------------------------------------- one question
def answer(cur, model, condition, q, schema, docs, samples):
    history, total_latency, prompt_chars = [], 0.0, 0
    # baseline: names only, 1 try | docs_only: documentation + samples, 1 try | spider2: + feedback loop
    attempts = MAX_ATTEMPTS if condition == "spider2" else 1
    sql, rows, error = "", None, None
    for _ in range(attempts):
        prompt = (baseline_prompt(schema, q["question"]) if condition == "baseline"
                  else spider2_prompt(schema, docs, samples, q["question"], history))
        prompt_chars += len(prompt)
        text, latency = complete(cur, model, prompt)
        total_latency += latency
        sql = extract_sql(text)
        rows, error = run_sql(cur, sql)
        if error:
            history.append((sql, f"ERROR: {error}"))
        elif not rows:
            history.append((sql, "The query ran but returned 0 rows."))
        else:
            break
    return sql, rows, error, len(history) + (0 if error or not rows else 1), total_latency, prompt_chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--conditions", default="baseline,spider2")
    args = ap.parse_args()

    questions = json.loads((EVAL_DIR / "questions.json").read_text(encoding="utf-8"))[: args.limit]
    docs = (EVAL_DIR / "schema_docs.md").read_text(encoding="utf-8")
    conn, cur = connect()
    model = pick_model(cur, args.model)
    schema, samples = schema_listing(cur), sample_values(cur)
    run_id = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    print(f"Model: {model}   questions: {len(questions)}   run: {run_id}\n")

    gold = {}
    for q in questions:
        rows, err = run_sql(cur, q["gold_sql"])
        if err:
            raise SystemExit(f"Gold SQL for {q['id']} failed: {err}")
        gold[q["id"]] = rows

    results = []
    for condition in args.conditions.split(","):
        for q in questions:
            sql, rows, error, attempts, latency, chars = answer(cur, model, condition, q, schema, docs, samples)
            ok = is_correct(gold[q["id"]], rows)
            results.append(dict(run_id=run_id, model=model, condition=condition, qid=q["id"],
                                difficulty=q["difficulty"], pattern=q["pattern"], question=q["question"],
                                predicted_sql=sql, attempts=attempts, executed=error is None,
                                correct=ok, latency_s=round(latency, 2), prompt_chars=chars,
                                error=error or ""))
            print(f"{condition:<9} {q['id']}  {'PASS' if ok else 'FAIL'}  attempts={attempts}  {latency:5.1f}s  {q['pattern']}")

    # summary
    print("\n" + "=" * 78)
    print(f"{'condition':<10}{'accuracy':>10}{'valid SQL':>11}{'avg latency':>13}{'avg prompt':>12}{'avg attempts':>14}")
    for c in args.conditions.split(","):
        r = [x for x in results if x["condition"] == c]
        n = len(r)
        print(f"{c:<10}{100*sum(x['correct'] for x in r)/n:>9.1f}%{100*sum(x['executed'] for x in r)/n:>10.1f}%"
              f"{sum(x['latency_s'] for x in r)/n:>12.1f}s{sum(x['prompt_chars'] for x in r)/n/4:>9,.0f} tok"
              f"{sum(x['attempts'] for x in r)/n:>14.2f}")
    print("\nAccuracy by pattern:")
    for p in sorted({x["pattern"] for x in results}):
        cells = []
        for c in args.conditions.split(","):
            r = [x for x in results if x["condition"] == c and x["pattern"] == p]
            cells.append(f"{c} {sum(x['correct'] for x in r)}/{len(r)}")
        print(f"  {p:<28}" + "   ".join(cells))

    # save
    out_dir = EVAL_DIR / "results"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"text2sql_{run_id}.csv"
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=results[0].keys())
        w.writeheader()
        w.writerows(results)
    cur.execute("""CREATE TABLE IF NOT EXISTS REGRADAR_DB.APP.TEXT2SQL_EVAL (
        run_id STRING, model STRING, condition STRING, qid STRING, difficulty STRING, pattern STRING,
        question STRING, predicted_sql STRING, attempts NUMBER, executed BOOLEAN, correct BOOLEAN,
        latency_s FLOAT, prompt_chars NUMBER, error STRING, run_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())""")
    cur.executemany("""INSERT INTO REGRADAR_DB.APP.TEXT2SQL_EVAL
        (run_id, model, condition, qid, difficulty, pattern, question, predicted_sql, attempts,
         executed, correct, latency_s, prompt_chars, error)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        [tuple(r.values()) for r in results])
    conn.commit()
    cur.close()
    conn.close()
    print(f"\nSaved {out.relative_to(ROOT)} and REGRADAR_DB.APP.TEXT2SQL_EVAL (run_id {run_id})")


if __name__ == "__main__":
    main()
