#!/usr/bin/env bash
# =============================================================================
# 💬 discord-backup.sh — off-site state backup to a private Discord channel
# =============================================================================
# Splits large archives into 24 MiB chunks and uploads them via Discord Webhook.
# Generates a JSON manifest with direct CDN download URLs for seamless restore.
#
# Config (read from supabase/.env, or from the environment):
#   DISCORD_BACKUP_WEBHOOK - Webhook URL for your private #db-backups channel
#
# Usage:
#   discord-backup.sh push <file>            # chunk, upload via webhook, post embed
#   discord-backup.sh restore <manifest> [outfile] # download chunks & reassemble
# =============================================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_ENV="$BASE_DIR/.env"
ROOT_ENV="$BASE_DIR/../.env"

CHUNK_BYTES=$((24 * 1024 * 1024)) # 24 MiB (Discord standard upload limit is 25 MiB)
DISCORD_BACKUP_WEBHOOK="${DISCORD_BACKUP_WEBHOOK:-}"

load_cfg() {
  local env_file
  for env_file in "$CF_ENV" "$ROOT_ENV"; do
    [ -f "$env_file" ] || continue
    [ -n "$DISCORD_BACKUP_WEBHOOK" ] || DISCORD_BACKUP_WEBHOOK="$(grep -E '^DISCORD_BACKUP_WEBHOOK=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  done
  export DISCORD_BACKUP_WEBHOOK
}

cfg_ok() {
  [ -n "$DISCORD_BACKUP_WEBHOOK" ]
}

# ---------------------------------------------------------------------------
cmd_push() {
  local file="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ℹ️  Discord backup SKIPPED — DISCORD_BACKUP_WEBHOOK not configured"
    return 0
  fi
  [ -n "$file" ] || { echo "  ⚠️  usage: discord-backup.sh push <file>"; return 1; }
  [ -s "$file" ] || { echo "  💬 nothing to push ($file missing/empty)"; return 0; }

  if ! tar -tzf "$file" >/dev/null 2>&1; then
    echo "  ERROR: refusing to upload an invalid state archive: $file" >&2
    return 1
  fi

  local size base sha tmp parts total_parts
  size="$(stat -c%s "$file")"
  base="$(basename "$file")"
  sha="$(sha256sum "$file" | cut -d' ' -f1)"
  tmp="$(mktemp -d)"

  if ! split -b "$CHUNK_BYTES" -d -a 3 "$file" "$tmp/chunk."; then
    echo "  ERROR: could not split archive for Discord webhook" >&2
    rm -rf "$tmp"
    return 1
  fi

  total_parts="$(ls "$tmp"/chunk.* 2>/dev/null | wc -l | tr -d ' ')"
  echo "  💬 pushing backup to Discord (${total_parts} chunks, $(du -h "$file" | cut -f1))..."

  # Send start notification embed
  curl -sS -o /dev/null -X POST "$DISCORD_BACKUP_WEBHOOK" \
    -H "Content-Type: application/json" \
    --data "{\"embeds\":[{\"title\":\"🚀 Supabase Backup Upload Started\",\"description\":\"**Archive:** \`$base\`\\n**Size:** $(du -h "$file" | cut -f1) ($size bytes)\\n**Total Chunks:** $total_parts (24 MiB each)\\n**SHA256:** \`$sha\`\",\"color\":3447003,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}" || true

  local part_idx=0 uploaded_urls="[]"
  for f in "$tmp"/chunk.*; do
    part_idx=$((part_idx + 1))
    local part_name="${f##*/}"
    local part_size
    part_size="$(stat -c%s "$f")"

    local resp code resp_file
    resp_file="$(mktemp)"
    code="$(curl -sS --max-time 120 -o "$resp_file" -w '%{http_code}' \
      -X POST "$DISCORD_BACKUP_WEBHOOK?wait=true" \
      -F "payload_json={\"content\":\"📦 **Chunk [$part_idx/$total_parts]** • \`$part_name\` ($((part_size / 1024 / 1024)) MB)\"}" \
      -F "files[0]=@$f" || true)"

    if [ "$code" != "200" ]; then
      echo "  ⚠️  Discord chunk $part_idx upload failed with HTTP $code" >&2
      rm -f "$resp_file"
      rm -rf "$tmp"
      return 1
    fi

    local cdn_url
    cdn_url="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["attachments"][0]["url"])
except Exception:
    sys.exit(1)
' "$resp_file" 2>/dev/null || echo "")"
    rm -f "$resp_file"

    if [ -z "$cdn_url" ]; then
      echo "  ⚠️  could not retrieve CDN URL for chunk $part_idx" >&2
      rm -rf "$tmp"
      return 1
    fi

    uploaded_urls="$(python3 -c '
import json, sys
urls = json.loads(sys.argv[1])
urls.append({"part": int(sys.argv[2]), "file": sys.argv[3], "url": sys.argv[4]})
print(json.dumps(urls))
' "$uploaded_urls" "$part_idx" "$part_name" "$cdn_url")"

    # Avoid Discord webhook aggressive rate limits (sleep 1s between parts)
    [ "$part_idx" -lt "$total_parts" ] && sleep 1
  done

  # Save local manifest with CDN URLs
  local manifest_json
  manifest_json="$(python3 -c '
import json, sys, time
manifest = {
    "version": 1,
    "file": sys.argv[1],
    "size": int(sys.argv[2]),
    "sha256": sys.argv[3],
    "timestamp": int(time.time()),
    "parts": json.loads(sys.argv[4])
}
print(json.dumps(manifest, indent=2))
' "$base" "$size" "$sha" "$uploaded_urls")"

  printf '%s' "$manifest_json" > "$BASE_DIR/discord-manifest.json"

  # Post completion embed
  curl -sS -o /dev/null -X POST "$DISCORD_BACKUP_WEBHOOK" \
    -H "Content-Type: application/json" \
    --data "{\"embeds\":[{\"title\":\"✅ Supabase Backup Complete & Verified\",\"description\":\"**Archive:** \`$base\`\\n**Size:** $(du -h "$file" | cut -f1)\\n**Chunks Uploaded:** $total_parts / $total_parts\\n**SHA256:** \`$sha\`\",\"color\":5763719,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}" || true

  echo "  ✅ Discord backup complete ($total_parts chunks uploaded, manifest saved to discord-manifest.json)"
  rm -rf "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
cmd_restore() {
  local manifest="${1:-}" outfile="${2:-./supabase-state.tar.gz}"
  [ -n "$manifest" ] && [ -f "$manifest" ] || manifest="$BASE_DIR/discord-manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "  ERROR: discord-manifest.json not found" >&2
    return 1
  fi

  local outdir tmp
  outdir="$(dirname "$outfile")"
  mkdir -p "$outdir"
  tmp="$(mktemp -d)"

  echo "  💬 restoring state archive from Discord manifest ($manifest)..."
  python3 -c '
import json, sys, urllib.request, hashlib

manifest_file = sys.argv[1]
tmp_dir = sys.argv[2]
out_file = sys.argv[3]

with open(manifest_file) as f:
    mf = json.load(f)

parts = sorted(mf["parts"], key=lambda x: x["part"])
expected_sha = mf["sha256"]
expected_size = mf["size"]

print(f"  Downloading {len(parts)} chunks from Discord CDN...")
with open(out_file, "wb") as out_fp:
    for p in parts:
        part_num = p["part"]
        url = p["url"]
        req = urllib.request.Request(url, headers={"User-Agent": "SupabaseBackup/1.0"})
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
            out_fp.write(data)
            print(f"    Chunk {part_num} OK ({len(data)} bytes)")

# Verify size and SHA256
with open(out_file, "rb") as fp:
    actual_data = fp.read()
    actual_sha = hashlib.sha256(actual_data).hexdigest()
    actual_size = len(actual_data)

if actual_size != expected_size:
    print(f"  ERROR: size mismatch (got {actual_size}, expected {expected_size})", file=sys.stderr)
    sys.exit(1)

if actual_sha != expected_sha:
    print(f"  ERROR: sha256 mismatch (got {actual_sha}, expected {expected_sha})", file=sys.stderr)
    sys.exit(1)

print("  ✅ Download and integrity verified!")
' "$manifest" "$tmp" "$outfile" || {
    echo "  ERROR: restore from Discord failed" >&2
    rm -rf "$tmp"
    return 1
  }

  rm -rf "$tmp"
  if ! tar -tzf "$outfile" >/dev/null 2>&1; then
    echo "  ERROR: restored archive is not a valid tar.gz" >&2
    rm -f "$outfile"
    return 1
  fi
  echo "  ✅ Discord archive restored successfully to $outfile"
  return 0
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  push)    shift; cmd_push "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) echo "usage: discord-backup.sh {push <file> | restore <manifest> [outfile]}"; exit 1 ;;
esac
