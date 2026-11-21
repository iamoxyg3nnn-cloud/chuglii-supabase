#!/usr/bin/env bash
# =============================================================================
# ☁️  cloudflare-backup.sh — off-site state backup to Cloudflare Workers KV
# =============================================================================
# Why KV (not R2): KV is card-free (no payment method required) and is usable
# with the wrangler/tunnel credentials this stack already has. KV caps each
# value at 25 MiB, so larger archives are split into CHUNK_BYTES-sized chunks.
#
# Namespace layout:
#   archive/<generation>/<base>.<NNNNNNNN>  immutable archive chunks
#   archive/<generation>/manifest.json      verified archive manifest
#   latest/manifest.json                    pointer to the current generation
#
# Retention: the freshest set is always under 'latest/' (overwritten each
# push). Chunks are immutable and the latest pointer changes only after the
# full generation has been read back and verified. Failed uploads therefore
# cannot corrupt the last known-good backup.
#
# The runner keeps no growing local history either: snapshots overwrite a single
# on-disk archive and chunk temp dirs are removed after each push.
#
# Usage:
#   cloudflare-backup.sh push <file>            # verify, publish + prune expired
#   cloudflare-backup.sh restore <outfile>      # pull latest and reassemble
#   cloudflare-backup.sh manifest               # print latest backup's unix ts
#   cloudflare-backup.sh verify                 # confirm 'latest' is restorable (size+sha256)
#   cloudflare-backup.sh refresh                # renew access token from the .env refresh token
#   cloudflare-backup.sh list                   # show keys + retention state
#   cloudflare-backup.sh prune                  # prune backups > 7 days (guarantees >= 1 backup kept)
#
# NOTE on OAuth tokens: Cloudflare 'cfor*' refresh tokens are SINGLE-USE and
# rotate on every mint. The workflow keeps the rotated token in supabase/.env so
# the chain survives on a persistent runner; a fresh runner needs either a
# permanent API token (preferred — set CLOUDFLARE_BACKUP_TOKEN to it) or a
# re-seeded refresh token.
#
# Config (read from supabase/.env, or from the environment):
#   CF_ACCOUNT_ID, CF_KV_NAMESPACE_ID, CF_API_TOKEN
#   (CF_API_TOKEN needs Workers KV Storage → Edit on the account)
# =============================================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_ENV="$BASE_DIR/.env"
ROOT_ENV="$BASE_DIR/../.env"

CHUNK_BYTES=$((24 * 1024 * 1024))   # 24 MiB (KV hard limit is 25 MiB)
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"  # prune backups older than 7 days
MAX_KEEP_ARCHIVES="${MAX_KEEP_ARCHIVES:-2}"          # max complete generations kept (fits 1 GB quota)
MIN_KEEP_ARCHIVES=1                                  # absolute safety floor: never delete the only backup
RESTORE_ATTEMPTS=20                                  # allow time for KV edge propagation during restore

CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_KV_NAMESPACE_ID="${CF_KV_NAMESPACE_ID:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_REFRESH_TOKEN="${CF_REFRESH_TOKEN:-}"

# Wrangler OAuth app (public client, used by `wrangler login`) — lets us renew
# the short-lived access token from the long-lived refresh token. Cloudflare's
# token endpoint also accepts Basic auth w/ client_id:client_secret, but this
# OAuth client is public so body-only is enough (matches wrangler's own code).
CF_OAUTH_CLIENT_ID="54d11594-84e4-41aa-b438-e81b8fa78ee7"

# ---------------------------------------------------------------------------
load_cfg() {
  local env_file
  for env_file in "$CF_ENV" "$ROOT_ENV"; do
    [ -f "$env_file" ] || continue
    [ -n "$CF_ACCOUNT_ID" ] || CF_ACCOUNT_ID="$(grep -E '^CF_ACCOUNT_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_KV_NAMESPACE_ID" ] || CF_KV_NAMESPACE_ID="$(grep -E '^CF_KV_NAMESPACE_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_API_TOKEN" ] || CF_API_TOKEN="$(grep -E '^CF_API_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_API_TOKEN" ] || CF_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_REFRESH_TOKEN" ] || CF_REFRESH_TOKEN="$(grep -E '^CF_REFRESH_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  done
}

# Renew the OAuth access token from CF_REFRESH_TOKEN; rotates the refresh token
# too (Cloudflare refresh tokens are single-use) and persists both to .env so
# later snapshots and sibling processes stay in sync. The rotated token is also
# written to .cf-creds, which is archived with the state — without that, a
# rotation mid-session left the NEXT session holding an already-consumed token
# and the off-site backup chain died after one session.
cf_refresh_token() {
  [ -n "$CF_REFRESH_TOKEN" ] || return 1
  local resp at rt
  resp="$(curl -sS --max-time 20 -X POST "https://dash.cloudflare.com/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=refresh_token&refresh_token=$CF_REFRESH_TOKEN&client_id=$CF_OAUTH_CLIENT_ID")"
  at="$(printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [ -n "$at" ] || return 1
  rt="$(printf '%s' "$resp" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')"
  CF_API_TOKEN="$at"
  if [ -f "$CF_ENV" ]; then
    sed -i -E '/^CF_API_TOKEN=/d; /^CF_REFRESH_TOKEN=/d' "$CF_ENV" 2>/dev/null || true
    {
      echo "CF_API_TOKEN=$at"
      [ -n "$rt" ] && echo "CF_REFRESH_TOKEN=$rt"
    } >> "$CF_ENV"
  fi
  # Archive-visible copy of the (single-use) refresh token — only overwrite
  # when Cloudflare actually handed back a rotation.
  if [ -n "$rt" ]; then
    printf 'CF_REFRESH_TOKEN=%s\n' "$rt" > "$BASE_DIR/.cf-creds" 2>/dev/null || true
    chmod 600 "$BASE_DIR/.cf-creds" 2>/dev/null || true
  fi
  echo "  ☁️  Cloudflare OAuth access token refreshed (~1h)"
  return 0
}

# put with a single 401 → refresh-retry (access tokens only live ~1h).
put_with_retry() {
  local status
  put_value "$1" "$2"
  status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if [ "$status" -eq 2 ] && cf_refresh_token; then
    put_value "$1" "$2"
    return $?
  fi
  if [ "$status" -eq 3 ]; then
    return 3
  fi
  return 1
}

cfg_ok() {
  [ -n "$CF_ACCOUNT_ID" ] && [ -n "$CF_KV_NAMESPACE_ID" ] && [ -n "$CF_API_TOKEN" ]
}

# URL-encode only what our generated keys contain (keeps path-safe chars intact)
urlenc() {
  local s="$1" c
  local i len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
list_keys() {  # list_keys <urlencoded-prefix> -> one key per line, may paginate
  local prefix="$1" cursor="" body keys
  while :; do
    local q="?limit=1000&prefix=$prefix"
    [ -n "$cursor" ] && q="$q&cursor=$(urlenc "$cursor")"
    body="$(curl -fsS --max-time 30 "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/keys$q" \
      -H "Authorization: Bearer $CF_API_TOKEN")"
    if ! keys="$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("success") is not True:
    raise SystemExit(1)
for item in d.get("result", []):
    print(item["name"])
')"; then
      echo "  ERROR: Cloudflare KV returned an invalid key-list response" >&2
      return 1
    fi
    [ -n "$keys" ] && printf '%s\n' "$keys"
    if ! cursor="$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("success") is not True:
    raise SystemExit(1)
print(d.get("result_info", {}).get("cursor") or d.get("cursor") or "")
')"; then
      echo "  ERROR: Cloudflare KV returned an invalid pagination response" >&2
      return 1
    fi
    [ -z "$cursor" ] && break
  done
}

# Bulk delete keys from Cloudflare KV (fast + uses 1 API call per batch)
bulk_delete_keys() {
  local doomed_file="$1" code keys_json count
  [ -s "$doomed_file" ] || return 0
  count="$(wc -l < "$doomed_file" | tr -d ' ')"
  [ "$count" -eq 0 ] && return 0

  keys_json="$(python3 -c '
import sys, json
keys = [line.strip() for line in open(sys.argv[1]) if line.strip()]
print(json.dumps(keys))
' "$doomed_file" 2>/dev/null)" || return 1

  code="$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' -X DELETE \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/bulk" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$keys_json" || true)"

  if [ "$code" = "200" ]; then
    return 0
  fi

  # Fallback to per-key deletion if bulk delete endpoint fails
  echo "  ⚠️  bulk delete returned HTTP ${code:-000}; falling back to individual deletes"
  local k enc_key status=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    enc_key="$(urlenc "$k")"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$enc_key" \
      -H "Authorization: Bearer $CF_API_TOKEN" || true)"
    if [ "$code" != "200" ] && [ "$code" != "404" ]; then
      echo "  ⚠️  delete of $k returned HTTP $code"
      status=1
    fi
  done < "$doomed_file"
  return $status
}

prune_archives() {
  local mode="${1:-normal}"
  local all latest_generation="" latest_tmp latest_status
  # List all keys to evaluate archive/ generations, incomplete chunks, and legacy keys
  if ! all="$(list_keys '')"; then
    echo "  ⚠️  archive pruning skipped because KV listing was incomplete"
    return 1
  fi
  [ -z "$all" ] && return 0

  latest_tmp="$(mktemp)"
  get_value "latest/manifest.json" "$latest_tmp"
  latest_status=$?
  if [ "$latest_status" -eq 0 ]; then
    latest_generation="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("generation", ""))
' "$latest_tmp" 2>/dev/null)" || true
  fi
  rm -f "$latest_tmp"

  local doomed_tmp plan_summary
  doomed_tmp="$(mktemp)"

  plan_summary="$(printf '%s\n' "$all" | python3 -c '
import sys, json, time

mode = "'"$mode"'"
retention_days = int("'"${BACKUP_RETENTION_DAYS:-7}"'")
max_keep = int("'"${MAX_KEEP_ARCHIVES:-2}"'")
if mode == "pre-push":
    # Edge case protection: ensure space for incoming backup by pruning down to max_keep - 1 (min 1)
    max_keep = max(1, max_keep - 1)

latest_gen = "'"${latest_generation:-}"'"
now = int(time.time())
max_age_secs = retention_days * 86400

all_keys = [line.strip() for line in sys.stdin if line.strip()]

generations = {}
legacy_keys = []
for k in all_keys:
    if k.startswith("archive/"):
        parts = k.split("/")
        if len(parts) >= 2:
            generations.setdefault(parts[1], []).append(k)
    elif k.startswith("latest/"):
        if k != "latest/manifest.json":
            legacy_keys.append(k)
    else:
        legacy_keys.append(k)

complete_gens = []
incomplete_gens = []
for g, g_keys in generations.items():
    has_manifest = any(k.endswith("/manifest.json") for k in g_keys)
    try:
        ts = int(g[:10])
    except Exception:
        ts = 0
    # Edge case protection: clock skew in future
    if ts > now + 86400:
        ts = now
    if has_manifest:
        complete_gens.append({"gen": g, "ts": ts, "keys": g_keys})
    else:
        incomplete_gens.append({"gen": g, "ts": ts, "keys": g_keys})

# Sort complete generations chronologically ascending (oldest first)
complete_gens.sort(key=lambda x: x["ts"])
doomed_keys = list(legacy_keys)
kept_gens = set()

# Edge case: incomplete generations older than 30 mins are abandoned uploads
for inc in incomplete_gens:
    inc_age = max(0, now - inc["ts"]) if inc["ts"] > 0 else 999999
    if inc_age > 1800:
        doomed_keys.extend(inc["keys"])

total_complete = len(complete_gens)

if total_complete <= 1:
    # SAFEGUARD: If only 1 backup exists, NEVER delete it regardless of age or pre-push!
    if total_complete == 1:
        g = complete_gens[0]["gen"]
        kept_gens.add(g)
        msg = f"Only 1 complete backup exists ({g}) — protected by safety rule! Never deleted."
    else:
        msg = "No complete backups found in KV."
else:
    # Multiple complete backups exist
    # 1. Newest complete generation is ALWAYS protected
    newest = complete_gens[-1]
    kept_gens.add(newest["gen"])
    if latest_gen:
        kept_gens.add(latest_gen)

    # 2. Evaluate older candidates (from newest down to oldest)
    candidates = [c for c in complete_gens if c["gen"] not in kept_gens]
    for cand in reversed(candidates):
        g = cand["gen"]
        age = max(0, now - cand["ts"])
        # Prune if expired (> retention_days) OR exceeds max_keep target
        if age > max_age_secs:
            doomed_keys.extend(cand["keys"])
        elif len(kept_gens) >= max_keep:
            doomed_keys.extend(cand["keys"])
        else:
            kept_gens.add(g)

    msg = f"Evaluated {total_complete} complete backups ({mode}): keeping {len(kept_gens)}, pruning {total_complete - len(kept_gens)} (retention: {retention_days}d, max: {max_keep})."

# Ensure all doomed keys for non-kept complete generations are marked
for cg in complete_gens:
    if cg["gen"] not in kept_gens:
        for k in cg["keys"]:
            if k not in doomed_keys:
                doomed_keys.append(k)

with open(sys.argv[1], "w") as f:
    for dk in doomed_keys:
        f.write(dk + "\n")

print(msg)
' "$doomed_tmp" 2>/dev/null)"

  echo "  ☁️  $plan_summary"

  local doomed_count
  doomed_count="$(wc -l < "$doomed_tmp" | tr -d ' ')"
  if [ "$doomed_count" -gt 0 ]; then
    echo "  🧹 pruning $doomed_count expired/orphaned key(s) from Cloudflare KV..."
    if bulk_delete_keys "$doomed_tmp"; then
      echo "  ✅ pruned $doomed_count key(s) successfully"
    else
      echo "  ⚠️  pruning encountered errors for some keys"
    fi
  else
    echo "  ✅ storage healthy — no keys require pruning"
  fi
  rm -f "$doomed_tmp"
}

put_value() {  # put_value <key> <file>
  local key="$1" file="$2" code resp_file
  resp_file="$(mktemp)"
  code="$(curl -sS --max-time 120 -o "$resp_file" -w '%{http_code}' -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/octet-stream" --data-binary "@$file" || true)"
  if [ "$code" = "200" ]; then
    rm -f "$resp_file"
    return 0
  fi
  if [ "$code" = "401" ]; then
    rm -f "$resp_file"
    return 2
  fi
  if [ "$code" = "429" ]; then
    local err_msg
    err_msg="$(grep -o '"message":"[^"]*"' "$resp_file" 2>/dev/null | head -1 | cut -d: -f2- | tr -d '"' || echo "daily usage limit reached")"
    echo "  ::warning::Cloudflare KV daily write limit reached (HTTP 429: ${err_msg}). Resets at 00:00 UTC." >&2
    # Mark cooldown until next 00:00 UTC so subsequent ticks do not spam retries
    python3 -c '
import time, datetime
now = datetime.datetime.now(datetime.timezone.utc)
tomorrow = (now + datetime.timedelta(days=1)).replace(hour=0, minute=0, second=5, microsecond=0)
print(int(tomorrow.timestamp()))
' > "$BASE_DIR/.cf_quota_exhausted" 2>/dev/null || true
    rm -f "$resp_file"
    return 3
  fi
  echo "  ERROR: Cloudflare KV upload of $key returned HTTP ${code:-000}" >&2
  rm -f "$resp_file"
  return 1
}

get_value() {  # get_value <key> <outfile>  (curl exit code 0 = found)
  local key="$1" dest="$2" code
  code="$(curl -sS --max-time 120 -o "$dest" -w '%{http_code}' \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN" || true)"
  [ "$code" = "200" ] && return 0
  rm -f "$dest"
  [ "$code" = "404" ] && return 2
  echo "  ERROR: Cloudflare KV download of $key returned HTTP ${code:-000}" >&2
  return 1
}

# ---------------------------------------------------------------------------
cmd_push() {
  # argv here is the ARGUMENTS ONLY: the dispatcher shifts the subcommand off, and
  # snapshot-state.sh invokes the CLI. Reading "$2" instead meant the positional was
  # always empty when cmd_verify called a sibling function directly.
  local file="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ::warning::Cloudflare backup SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$file" ] || { echo "  ⚠️  usage: cloudflare-backup.sh push <file>"; return 1; }
  [ -s "$file" ] || { echo "  ☁️  nothing to push ($file missing/empty)"; return 0; }

  local size base ts generation tmp sha manifest parts nn code attempt
  if ! tar -tzf "$file" >/dev/null 2>&1; then
    echo "  ERROR: refusing to upload an invalid state archive: $file" >&2
    return 1
  fi
  size="$(stat -c%s "$file")"
  base="$(basename "$file")"
  ts="$(date +%s)"
  generation="$(date +%s%N)"
  tmp="$(mktemp -d)"
  sha="$(sha256sum "$file" | cut -d' ' -f1)"

  # Edge case pre-flight check: refuse upload if single file exceeds Cloudflare KV free ceiling (950 MiB)
  local MAX_KV_BYTES=$((950 * 1024 * 1024))
  if [ "$size" -gt "$MAX_KV_BYTES" ]; then
    echo "  ::error::State archive ($size bytes) exceeds Cloudflare KV free storage limit (950 MiB). Upload aborted to avoid burning write quota." >&2
    rm -rf "$tmp"
    return 1
  fi

  # Pre-push pruning: prune older backups down to max_keep - 1 so the new upload has guaranteed headroom
  prune_archives "pre-push" || echo "  ⚠️  pre-push pruning skipped"

  if ! split -b "$CHUNK_BYTES" -d -a 8 "$file" "$tmp/chunk."; then
    echo "  ERROR: could not split state archive for Cloudflare KV" >&2
    rm -rf "$tmp"
    return 1
  fi
  parts=0
  for f in "$tmp"/chunk.*; do
    nn="${f##*.}"
    put_with_retry "archive/$generation/$base.$nn" "$f"
    code=$?
    if [ "$code" -ne 0 ]; then
      if [ "$code" -eq 3 ]; then
        echo "  ::warning::Cloudflare KV backup paused: account reached daily write limit (1,000 writes/day). Previous latest backup is safely preserved."
      else
        echo "  ::warning::Cloudflare backup: chunk $nn upload failed — previous latest preserved"
      fi
      rm -rf "$tmp"
      return 1
    fi
    attempt=0
    while [ "$attempt" -lt 5 ]; do
      attempt=$((attempt + 1))
      if get_value "archive/$generation/$base.$nn" "$tmp/readback.$nn" \
         && cmp -s "$f" "$tmp/readback.$nn"; then
        break
      fi
      [ "$attempt" -eq 5 ] || sleep 2
    done
    if [ "$attempt" -eq 5 ] && ! cmp -s "$f" "$tmp/readback.$nn"; then
      echo "  ::warning::Cloudflare backup: chunk $nn failed read-back verification — previous latest preserved"
      rm -rf "$tmp"
      return 1
    fi
    parts=$((parts + 1))
  done

  manifest="{\"version\":2,\"file\":\"$base\",\"ts\":$ts,\"generation\":\"$generation\",\"parts\":$parts,\"size\":$size,\"sha256\":\"$sha\"}"
  printf '%s' "$manifest" > "$tmp/manifest.json"
  if ! put_with_retry "archive/$generation/manifest.json" "$tmp/manifest.json"; then
    echo "  ::warning::Cloudflare archive manifest upload failed — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if get_value "archive/$generation/manifest.json" "$tmp/manifest.readback.json" \
       && cmp -s "$tmp/manifest.json" "$tmp/manifest.readback.json"; then
      break
    fi
    [ "$attempt" -eq 5 ] || sleep 2
  done
  if [ "$attempt" -eq 5 ] && ! cmp -s "$tmp/manifest.json" "$tmp/manifest.readback.json"; then
    echo "  ::warning::Cloudflare archive manifest failed read-back verification — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi

  if ! put_with_retry "latest/manifest.json" "$tmp/manifest.json"; then
    echo "  ⚠️  latest manifest upload failed — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if get_value "latest/manifest.json" "$tmp/latest.readback.json" \
       && cmp -s "$tmp/manifest.json" "$tmp/latest.readback.json"; then
      break
    fi
    [ "$attempt" -eq 5 ] || sleep 2
  done
  if [ "$attempt" -eq 5 ] && ! cmp -s "$tmp/manifest.json" "$tmp/latest.readback.json"; then
    echo "  ⚠️  latest manifest was not visible after upload; skipping retention pruning"
    rm -rf "$tmp"
    return 1
  fi

  echo "  ☁️  backup pushed and verified: $base (${parts}+1 keys, $(du -h "$file" | cut -f1)) → archive/$generation/"
  prune_archives || echo "  ⚠️  backup is safe; archive pruning will retry after the next upload"
  rm -rf "$tmp"
  return 0
}

# One attempt at restoring $1. Returns 2 when no backup exists, and 1 when the
# manifest, its chunks, or the assembled archive are invalid.
restore_once() {
  local outfile="$1"
  local tmp manifest mf base parts size sha generation prefix suffix_width ok outdir
  outdir="$(dirname "$outfile")"
  [ -d "$outdir" ] || return 1
  tmp="$(mktemp -d "$outdir/.cloudflare-restore.XXXXXX")"
  local get_status
  get_value "latest/manifest.json" "$tmp/manifest.json"
  get_status=$?
  if [ "$get_status" -ne 0 ]; then
    rm -rf "$tmp"
    if [ "$get_status" -eq 2 ]; then
      echo "  ☁️  no backup found in Cloudflare (latest/manifest.json missing)"
      return 2
    fi
    return 1
  fi
  if [ ! -s "$tmp/manifest.json" ]; then
    echo "  ☁️  no backup found in Cloudflare (latest/manifest.json missing)"
    rm -rf "$tmp"
    return 2
  fi
  mf="$(cat "$tmp/manifest.json")"
  base="$(printf '%s' "$mf" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
  parts="$(printf '%s' "$mf" | sed -n 's/.*"parts":\([0-9]*\).*/\1/p')"
  size="$(printf '%s' "$mf" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
  sha="$(printf '%s' "$mf" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')"
  generation="$(printf '%s' "$mf" | sed -n 's/.*"generation":"\([0-9]*\)".*/\1/p')"
  if ! [[ "$base" =~ ^[A-Za-z0-9._-]{1,128}$ ]] \
     || ! [[ "$parts" =~ ^[0-9]{1,8}$ ]] \
     || ! [[ "$size" =~ ^[0-9]{1,18}$ ]] \
     || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]] \
     || [ "$parts" -lt 1 ] || [ "$size" -lt 1 ]; then
    echo "  ⚠️  manifest unreadable"
    rm -rf "$tmp"
    return 1
  fi
  if [ -n "$generation" ]; then
    if ! [[ "$generation" =~ ^[0-9]{1,24}$ ]]; then
      echo "  ⚠️  manifest generation is invalid"
      rm -rf "$tmp"
      return 1
    fi
    prefix="archive/$generation"
    suffix_width=8
  else
    prefix="latest"
    suffix_width=2
  fi
  local expected_parts=$(( (size + CHUNK_BYTES - 1) / CHUNK_BYTES ))
  if [ "$parts" -ne "$expected_parts" ]; then
    echo "  ⚠️  manifest chunk count does not match the archive size"
    rm -rf "$tmp"
    return 1
  fi

  for ((i = 0; i < parts; i++)); do
    nn="$(printf "%0${suffix_width}d" "$i")"
    if ! get_value "$prefix/$base.$nn" "$tmp/part.$nn"; then
      echo "  ⚠️  chunk $prefix/$base.$nn missing or unreadable"
      rm -rf "$tmp"
      return 1
    fi
  done
  : > "$tmp/archive"
  for ((i = 0; i < parts; i++)); do
    nn="$(printf "%0${suffix_width}d" "$i")"
    cat "$tmp/part.$nn" >> "$tmp/archive"
  done

  local got
  got="$(stat -c%s "$tmp/archive")"
  if [ "$got" != "$size" ]; then
    echo "  ⚠️  size mismatch (got ${got}B, expected ${size}B) — discarding"
    rm -rf "$tmp"
    return 1
  fi
  local gotsha
  gotsha="$(sha256sum "$tmp/archive" | cut -d' ' -f1)"
  if [ "$gotsha" != "$sha" ]; then
    echo "  ⚠️  sha256 mismatch — discarding"
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -tzf "$tmp/archive" >/dev/null 2>&1; then
    echo "  ⚠️  downloaded state archive is not a valid tar.gz"
    rm -rf "$tmp"
    return 1
  fi
  if ! mv -f "$tmp/archive" "$outfile"; then
    echo "  ERROR: could not install the verified Cloudflare backup at $outfile" >&2
    rm -rf "$tmp"
    return 1
  fi
  echo "  ☁️  restored from Cloudflare: $outfile (${parts} chunks, $(du -h "$outfile" | cut -f1), sha256 ok)"
  rm -rf "$tmp"
  return 0
}

# Versioned chunk keys keep readers on a complete immutable generation even
# while a later snapshot is uploading.
cmd_restore() {
  # argv is ARGUMENTS ONLY (dispatcher shifts the subcommand). cmd_verify calls this
  # with a single path, so "$2" was empty and restore always printed its usage line.
  local outfile="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare restore SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$outfile" ] || { echo "  ⚠️  usage: cloudflare-backup.sh restore <outfile>"; return 1; }

  local attempt restore_status
  for ((attempt = 1; attempt <= RESTORE_ATTEMPTS; attempt++)); do
    restore_once "$outfile"
    restore_status=$?
    if [ "$restore_status" -eq 0 ]; then
      return 0
    fi
    if [ "$restore_status" -eq 2 ]; then
      return 2
    fi
    echo "  ⏳  backup read failed validation (attempt ${attempt}/${RESTORE_ATTEMPTS}) — retrying in 2s"
    if [ "$attempt" -lt "$RESTORE_ATTEMPTS" ]; then
      sleep 2
    fi
  done
  echo "  ⚠️  restore failed after ${RESTORE_ATTEMPTS} attempts — the backup is inconsistent"
  return 1
}

# Print the unix ts of the freshest off-site backup (stdout only, nothing on
# failure). The restore step compares this against the cached archive's
# embedded state-ts and adopts whichever is NEWER — a cancelled session never
# reaches the end-of-run cache save, so the KV mirror can be the only recent
# copy of the state.
cmd_manifest() {
  load_cfg
  cfg_ok || return 0
  local tmp status
  tmp="$(mktemp)"
  get_value "latest/manifest.json" "$tmp"
  status=$?
  if [ "$status" -eq 2 ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  local ts
  if ! ts="$(python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)
ts = manifest.get("ts")
if isinstance(ts, bool) or not isinstance(ts, int) or ts < 0:
    raise SystemExit(1)
print(ts)
PY
)"; then
    echo "  ERROR: latest Cloudflare backup manifest is invalid" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  printf '%s' "$ts"
  return 0
}

cmd_refresh() {
  load_cfg
  if [ -z "$CF_REFRESH_TOKEN" ]; then
    echo "  ⚠️  no refresh token in .env — nothing to refresh"
    return 1
  fi
  if cf_refresh_token; then
    echo "  ☁️  access token renewed from the .env refresh token"
    return 0
  fi
  echo "  ⚠️  refresh from .env failed (token expired/revoked)"
  return 1
}

cmd_verify() {
  local tmp rc=0
  load_cfg
  if ! cfg_ok; then
    echo "  ⚠️  Cloudflare verify SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  tmp="$(mktemp -d)"
  cmd_restore "$tmp/candidate.tar.gz" || rc=1
  if [ "$rc" = 0 ] && [ -s "$tmp/candidate.tar.gz" ]; then
    echo "  ☁️  verify OK — latest backup is restorable ($(du -h "$tmp/candidate.tar.gz" | cut -f1))"
  else
    echo "  ::warning::Cloudflare verify FAILED — latest backup is NOT restorable"
    rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

cmd_list() {
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare KV not configured"; return 0
  fi
  local all n
  if ! all="$(list_keys '')"; then
    echo "  ERROR: could not list Cloudflare KV backup keys" >&2
    return 1
  fi
  n="$(printf '%s\n' "$all" | grep -c '^latest\|^archive' || true)"
  if [ -z "$all" ]; then
    echo "  ☁️  namespace empty"
  else
    echo "  ☁️  $n keys:"
    printf '%s\n' "$all" | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
cmd_prune() {
  load_cfg
  if ! cfg_ok; then
    echo "  ⚠️  Cloudflare prune SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  prune_archives
}

case "${1:-}" in
  push)    shift; cmd_push "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  manifest) cmd_manifest "$@" ;;
  verify)  cmd_verify "$@" ;;
  refresh) cmd_refresh "$@" ;;
  list)    cmd_list ;;
  prune)   cmd_prune ;;
  *) echo "usage: cloudflare-backup.sh {push <file> | restore <outfile> | manifest | verify | refresh | list | prune}"; exit 1 ;;
esac