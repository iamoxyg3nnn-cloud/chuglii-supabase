#!/usr/bin/env bash
# =============================================================================
# 🤗 huggingface-backup.sh — off-site state backup to Hugging Face Private Datasets
# =============================================================================
# Hugging Face provides 50 GB of free storage per private dataset repository,
# backed by Git LFS on AWS S3. Files up to 50 GB can be uploaded in one piece
# without manual chunking.
#
# Config (read from supabase/.env, or from the environment):
#   HF_TOKEN   - Hugging Face User Access Token (with Write permission)
#   HF_REPO    - Target private dataset (e.g. "username/supabase-backup-vault")
#   HF_RETENTION_DAYS - Days to keep historical backups (default: 1)
#   HF_MAX_HISTORY    - Max number of dated history snapshots to keep,
#                       regardless of age (default: 12). Each snapshot is
#                       ~600 MB; free-tier private LFS storage is limited,
#                       so unbounded retention fills the quota and makes
#                       every subsequent upload fail.
#
# Usage:
#   huggingface-backup.sh push <file>            # upload latest + dated snapshot, prune > 7d
#   huggingface-backup.sh restore <outfile>      # download and verify latest archive
#   huggingface-backup.sh list                   # list files in dataset vault
#   huggingface-backup.sh prune                  # prune dated backups > 7d (keeps >= 1)
# =============================================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_ENV="$BASE_DIR/.env"
ROOT_ENV="$BASE_DIR/../.env"

HF_TOKEN="${HF_TOKEN:-}"
HF_REPO="${HF_REPO:-}"
HF_RETENTION_DAYS="${HF_RETENTION_DAYS:-7}"

load_cfg() {
  local env_file
  for env_file in "$CF_ENV" "$ROOT_ENV"; do
    [ -f "$env_file" ] || continue
    [ -n "$HF_TOKEN" ] || HF_TOKEN="$(grep -E '^HF_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$HF_REPO" ] || HF_REPO="$(grep -E '^HF_REPO=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "${HF_RETENTION_DAYS:-}" ] || HF_RETENTION_DAYS="$(grep -E '^HF_RETENTION_DAYS=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  done
  HF_RETENTION_DAYS="${HF_RETENTION_DAYS:-7}"
  export HF_TOKEN HF_REPO HF_RETENTION_DAYS
}

cfg_ok() {
  [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]
}

ensure_hf_hub() {
  if ! python3 -c "import huggingface_hub" >/dev/null 2>&1; then
    echo "  📦 installing huggingface_hub..."
    python3 -m pip install -q --upgrade --break-system-packages huggingface_hub >/dev/null 2>&1 || \
    python3 -m pip install -q --upgrade huggingface_hub >/dev/null 2>&1 || {
      echo "  ERROR: failed to install huggingface_hub" >&2
      return 1
    }
  fi
  return 0
}

# ---------------------------------------------------------------------------
cmd_push() {
  local file="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ℹ️  Hugging Face backup SKIPPED — HF_TOKEN / HF_REPO not configured"
    return 0
  fi
  [ -n "$file" ] || { echo "  ⚠️  usage: huggingface-backup.sh push <file>"; return 1; }
  [ -s "$file" ] || { echo "  🤗 nothing to push ($file missing/empty)"; return 0; }

  if ! tar -tf "$file" >/dev/null 2>&1; then
    echo "  ERROR: refusing to upload an invalid state archive: $file" >&2
    return 1
  fi

  ensure_hf_hub || return 1

  # Prune BEFORE pushing: free-tier private LFS storage is small, and old
  # snapshots must be deleted first or the new upload is rejected for quota.
  cmd_prune

  echo "  🤗 pushing backup to Hugging Face Private Dataset ($HF_REPO)..."
  python3 -c '
import os, sys, json, time, datetime
from huggingface_hub import HfApi

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO"]
file_path = sys.argv[1]
retention_days = int(os.environ.get("HF_RETENTION_DAYS", "7"))

api = HfApi(token=token)

def _err_details(e):
    """Return a full description of an huggingface_hub HTTP error.

    The bare exception str() is often just a Request ID with no status or
    body, which makes the failure impossible to diagnose from the logs.
    """
    parts = [repr(e)]
    resp = getattr(e, "response", None)
    if resp is not None:
        try:
            parts.append(f"HTTP {resp.status_code}")
            body = resp.text
            if body:
                parts.append(f"body: {body[:2000]}")
        except Exception:
            pass
    return " | ".join(parts)


def _upload_with_retry(api, *, path_or_fileobj, path_in_repo, repo_id, repo_type, commit_message, attempts=4):
    """Upload with exponential backoff (2s/8s/32s). Transient 429/5xx and
    Xet/LFS hiccups are common on large (~600 MB) uploads; retry those."""
    last_err = None
    for attempt in range(1, attempts + 1):
        try:
            api.upload_file(
                path_or_fileobj=path_or_fileobj,
                path_in_repo=path_in_repo,
                repo_id=repo_id,
                repo_type=repo_type,
                commit_message=commit_message,
            )
            return True
        except Exception as e:
            last_err = e
            if attempt < attempts:
                wait = 2 ** (2 * attempt - 1)  # 2s, 8s, 32s
                print(f"  ⚠️  upload attempt {attempt}/{attempts} failed: {_err_details(e)}", file=sys.stderr)
                print(f"      retrying in {wait}s...", file=sys.stderr)
                time.sleep(wait)
    print(f"  ERROR uploading {path_in_repo} to Hugging Face after {attempts} attempts: {_err_details(last_err)}", file=sys.stderr)
    return False


# 1. Ensure private dataset repository exists
try:
    api.create_repo(repo_id=repo_id, repo_type="dataset", private=True, exist_ok=True)
except Exception as e:
    print(f"  ERROR creating/accessing Hugging Face repo {repo_id}: {_err_details(e)}", file=sys.stderr)
    sys.exit(1)

# 2. Upload latest backup (overwrites latest pointer)
size_mb = os.path.getsize(file_path) / (1024 * 1024)
print(f"  Uploading latest/supabase-state.tar.zst ({size_mb:.1f} MB)...")
if not _upload_with_retry(
    api,
    path_or_fileobj=file_path,
    path_in_repo="latest/supabase-state.tar.zst",
    repo_id=repo_id,
    repo_type="dataset",
    commit_message=f"Update latest backup ({size_mb:.1f} MB)",
):
    sys.exit(1)

# 3. Upload dated historical snapshot
now_dt = datetime.datetime.now(datetime.timezone.utc)
date_str = now_dt.strftime("%Y-%m-%d-%H%M%S")
hist_path = f"history/supabase-state-{date_str}.tar.zst"
print(f"  Archiving {hist_path}...")
_upload_with_retry(
    api,
    path_or_fileobj=file_path,
    path_in_repo=hist_path,
    repo_id=repo_id,
    repo_type="dataset",
    commit_message=f"Snapshot {date_str}",
)

# 4. Save manifest metadata
import hashlib
with open(file_path, "rb") as f:
    sha = hashlib.sha256(f.read()).hexdigest()

manifest = {
    "version": 1,
    "timestamp": int(now_dt.timestamp()),
    "date": now_dt.isoformat(),
    "size": os.path.getsize(file_path),
    "sha256": sha,
    "file": os.path.basename(file_path)
}
with open("hf_manifest.json", "w") as mf:
    json.dump(manifest, mf, indent=2)

try:
    api.upload_file(
        path_or_fileobj="hf_manifest.json",
        path_in_repo="latest/manifest.json",
        repo_id=repo_id,
        repo_type="dataset",
        commit_message="Update manifest"
    )
finally:
    if os.path.exists("hf_manifest.json"):
        os.remove("hf_manifest.json")

print(f"  ✅ Hugging Face backup successful: {hist_path} (SHA: {sha[:16]}...)")
' "$file" || return 1

  return 0
}

# ---------------------------------------------------------------------------
cmd_restore() {
  local outfile="${1:-./supabase-state.tar.zst}"
  load_cfg
  if ! cfg_ok; then
    echo "  ERROR: HF_TOKEN / HF_REPO not configured" >&2
    return 1
  fi
  ensure_hf_hub || return 1

  local outdir
  outdir="$(dirname "$outfile")"
  mkdir -p "$outdir"

  echo "  🤗 downloading latest state from Hugging Face ($HF_REPO)..."
  python3 -c '
import os, sys, hashlib
from huggingface_hub import hf_hub_download

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO"]
out_file = sys.argv[1]

# Download latest archive (zstd is current; fall back to the legacy gzip
# name so a vault written by the pre-zstd code still restores)
try:
    downloaded = hf_hub_download(
        repo_id=repo_id,
        filename="latest/supabase-state.tar.zst",
        repo_type="dataset",
        token=token
    )
except Exception:
    downloaded = hf_hub_download(
        repo_id=repo_id,
        filename="latest/supabase-state.tar.gz",
        repo_type="dataset",
        token=token
    )

import shutil
shutil.copyfile(downloaded, out_file)
print(f"  Downloaded {out_file} ({os.path.getsize(out_file)} bytes)")
' "$outfile" || {
    echo "  ERROR: failed to download backup from Hugging Face" >&2
    return 1
  }

  if ! tar -tf "$outfile" >/dev/null 2>&1; then
    echo "  ERROR: downloaded Hugging Face archive is corrupt" >&2
    rm -f "$outfile"
    return 1
  fi
  echo "  ✅ Hugging Face state archive restored and verified"
  return 0
}

# ---------------------------------------------------------------------------
cmd_prune() {
  load_cfg
  if ! cfg_ok; then return 0; fi
  ensure_hf_hub || return 0

  python3 -c '
import os, sys, re, time, datetime
from huggingface_hub import HfApi

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO"]
retention_days = int(os.environ.get("HF_RETENTION_DAYS", "1"))
max_history = int(os.environ.get("HF_MAX_HISTORY", "12"))
now = time.time()
max_age_secs = retention_days * 86400

api = HfApi(token=token)
try:
    files = api.list_repo_files(repo_id=repo_id, repo_type="dataset")
except Exception as e:
    print(f"  ⚠️ Hugging Face pruning list failed: {e}")
    sys.exit(0)

hist_files = [f for f in files if f.startswith("history/supabase-state-") and (f.endswith(".tar.zst") or f.endswith(".tar.gz"))]

if len(hist_files) <= 1:
    print(f"  🤗 Hugging Face retention: {len(hist_files)} history backup exists — protected by sole-backup rule.")
    sys.exit(0)

# Parse timestamps from filename: history/supabase-state-YYYY-MM-DD-HHMMSS.tar.gz
parsed = []
for hf in hist_files:
    m = re.search(r"supabase-state-(\d{4}-\d{2}-\d{2}-\d{6})", hf)
    if m:
        try:
            dt = datetime.datetime.strptime(m.group(1), "%Y-%m-%d-%H%M%S").replace(tzinfo=datetime.timezone.utc)
            parsed.append((dt.timestamp(), hf))
        except Exception:
            pass

parsed.sort(key=lambda x: x[0])

# Keep at least the newest one; delete by age AND by count cap.
to_delete = []
for ts, path in parsed[:-1]:
    age = now - ts
    if age > max_age_secs:
        to_delete.append(path)

# Count cap: even fresh snapshots must go if there are too many (each is
# ~600 MB and free-tier storage is limited). Always keep the newest one.
kept = [p for _, p in parsed if p not in to_delete]
if len(kept) > max_history:
    to_delete.extend(kept[:-max_history])

to_delete = sorted(set(to_delete))

if to_delete:
    print(f"  🧹 Pruning {len(to_delete)} backup(s) (> {retention_days}d or beyond the {max_history}-snapshot cap) from Hugging Face...")
    for i in range(0, len(to_delete), 50):
        batch = to_delete[i:i+50]
        try:
            api.delete_files(repo_id=repo_id, repo_type="dataset", delete_patterns=batch, commit_message="Prune old backups (retention/count cap)")
            for p in batch:
                print(f"    - deleted {p}")
        except Exception as e:
            print(f"    ⚠️ failed to delete batch: {e}")
            for p in batch:
                try:
                    api.delete_file(path_in_repo=p, repo_id=repo_id, repo_type="dataset", commit_message=f"Prune expired backup {p}")
                    print(f"    - deleted {p}")
                except Exception as e2:
                    print(f"    ⚠️ failed to delete {p}: {e2}")
else:
    print(f"  ✅ Hugging Face retention healthy ({len(hist_files)} backups within {retention_days}d / {max_history} cap).")
' || true
}

# ---------------------------------------------------------------------------
cmd_list() {
  load_cfg
  if ! cfg_ok; then
    echo "  🤗 Hugging Face not configured (set HF_TOKEN & HF_REPO)"
    return 0
  fi
  ensure_hf_hub || return 1
  python3 -c '
import os
from huggingface_hub import HfApi
token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO"]
api = HfApi(token=token)
try:
    files = api.list_repo_files(repo_id=repo_id, repo_type="dataset")
    print(f"  🤗 Files in {repo_id}:")
    for f in sorted(files):
        print(f"      {f}")
except Exception as e:
    print(f"  ERROR: {e}")
'
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  push)    shift; cmd_push "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  prune)   cmd_prune ;;
  list)    cmd_list ;;
  *) echo "usage: huggingface-backup.sh {push <file> | restore <outfile> | prune | list}"; exit 1 ;;
esac
