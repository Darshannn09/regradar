"""Shared helpers for every RegRadar ingestion script.

- Paths are relative to the repo root, so scripts work from any folder.
- Keys come from the repo's .env file.
- http_get() retries network errors, rate limits (429), and server errors (5xx).
"""
import json
import os
import time
from datetime import date
from pathlib import Path

import requests
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = REPO_ROOT / "data"
TODAY = date.today().isoformat()

load_dotenv(REPO_ROOT / ".env")
_PLACEHOLDERS = {"", "your_key_here", "your_census_key", "your_legiscan_key"}


def data_dir(*parts):
    """Return data/<parts>, creating it if needed."""
    path = DATA_DIR.joinpath(*parts)
    path.mkdir(parents=True, exist_ok=True)
    return path


def env_key(name, required=True, hint=""):
    """Read a key from .env. Exits with a clear message if a required key is missing."""
    value = (os.getenv(name) or "").strip()
    if value in _PLACEHOLDERS:
        value = ""
    if required and not value:
        raise SystemExit(f"Missing {name} in .env. {hint}".strip())
    return value or None


def http_get(url, *, params=None, headers=None, timeout=60, retries=3, wait=5, rate_limit_wait=60):
    """GET with retries. Returns the response; callers decide how to treat 4xx answers."""
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            response = requests.get(url, params=params, headers=headers, timeout=timeout)
        except requests.RequestException as e:
            last_error = e
            print(f"    network error, retry {attempt}/{retries}: {e}")
            time.sleep(wait)
            continue
        if response.status_code == 429:
            print(f"    rate limited, waiting {rate_limit_wait} seconds...")
            time.sleep(rate_limit_wait)
            continue
        if response.status_code >= 500:
            last_error = f"HTTP {response.status_code}"
            print(f"    server error {response.status_code}, retry {attempt}/{retries}")
            time.sleep(wait)
            continue
        return response
    raise RuntimeError(f"GET failed after {retries} attempts: {url} ({last_error})")


def save_json(path, obj, indent=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=indent, default=str), encoding="utf-8")
    return path


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def newest(folder, pattern):
    """Newest file in data/<folder> matching pattern, or None."""
    files = sorted((DATA_DIR / folder).glob(pattern), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def rel(path):
    """Path relative to the repo root, for tidy printing."""
    try:
        return Path(path).resolve().relative_to(REPO_ROOT)
    except ValueError:
        return Path(path)
