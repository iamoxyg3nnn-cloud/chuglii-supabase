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
#   HF_RETENTION_DAYS - Days to keep historical backups (default: 7)
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

  if ! tar -tzf "$file" >/dev/null 2>&1; then
    echo "  ERROR: refusing to upload an invalid state archive: $file" >&2
    return 1
  fi

  ensure_hf_hub || return 1

  echo "  🤗 pushing backup to Hugging Face Private Dataset ($HF_REPO)..."
  python3 -c '
import os, sys, json, time, datetime
from huggingface_hub import HfApi

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO"]
file_path = sys.argv[1]
retention_days = int(os.environ.get("HF_RETENTION_DAYS", "7"))

api = HfApi(token=token)

# 1. Ensure private dataset repository exists
try:
    api.create_repo(repo_id=repo_id, repo_type="dataset", private=True, exist_ok=True)
except Exception as e:
    print(f"  ERROR creating/accessing Hugging Face repo {repo_id}: {e}", file=sys.stderr)
    sys.exit(1)

# 2. Upload latest backup (overwrites latest pointer)
size_mb = os.path.getsize(file_path) / (1024 * 1024)
print(f"  Uploading latest/supabase-state.tar.gz ({size_mb:.1f} MB)...")
try:
    api.upload_file(
        path_or_fileobj=file_path,
        path_in_repo="latest/supabase-state.tar.gz",
        repo_id=repo_id,
        repo_type="dataset",
        commit_message=f"Update latest backup ({size_mb:.1f} MB)"
    )
except Exception as e:
    print(f"  ERROR uploading latest to Hugging Face: {e}", file=sys.stderr)
    sys.exit(1)

# 3. Upload dated historical snapshot
now_dt = datetime.datetime.now(datetime.timezone.utc)
date_str = now_dt.strftime("%Y-%m-%d-%H%M%S")
hist_path = f"history/supabase-state-{date_str}.tar.gz"
print(f"  Archiving {hist_path}...")
try:
    api.upload_file(
        path_or_fileobj=file_path,
        path_in_repo=hist_path,
        repo_id=repo_id,
        repo_type="dataset",
        commit_message=f"Snapshot {date_str}"
    )
except Exception as e:
    print(f"  ⚠️ Warning: dated archive failed: {e}", file=sys.stderr)

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

  cmd_prune
  return 0
}

# ---------------------------------------------------------------------------
cmd_restore() {
  local outfile="${1:-./supabase-state.tar.gz}"
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

# Download latest archive
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

  if ! tar -tzf "$outfile" >/dev/null 2>&1; then
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
retention_days = int(os.environ.get("HF_RETENTION_DAYS", "7"))
now = time.time()
max_age_secs = retention_days * 86400

api = HfApi(token=token)
try:
    files = api.list_repo_files(repo_id=repo_id, repo_type="dataset")
except Exception as e:
    print(f"  ⚠️ Hugging Face pruning list failed: {e}")
    sys.exit(0)

hist_files = [f for f in files if f.startswith("history/supabase-state-") and f.endswith(".tar.gz")]

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

# Keep at least the newest one
to_delete = []
for ts, path in parsed[:-1]:
    age = now - ts
    if age > max_age_secs:
        to_delete.append(path)

if to_delete:
    print(f"  🧹 Pruning {len(to_delete)} expired backup(s) (> {retention_days}d) from Hugging Face...")
    for p in to_delete:
        try:
            api.delete_file(path_in_repo=p, repo_id=repo_id, repo_type="dataset", commit_message=f"Prune expired backup {p}")
            print(f"    - deleted {p}")
        except Exception as e:
            print(f"    ⚠️ failed to delete {p}: {e}")
else:
    print(f"  ✅ Hugging Face retention healthy ({len(hist_files)} backups within {retention_days} days).")
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
