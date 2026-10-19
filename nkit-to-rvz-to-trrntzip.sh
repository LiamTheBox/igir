#!/usr/bin/env bash
# nkit-to-rvz-to-trrntzip: convert Redump Wii .nkit.iso archives to verified .rvz with NKit,
# then wrap each .rvz (untouched) in a TorrentZip with igir.
#
#   nkit-to-rvz-to-trrntzip start            run in the background (survives closing VS Code)
#   nkit-to-rvz-to-trrntzip status | log     check on the background job
#   nkit-to-rvz-to-trrntzip stop             stop it (safe; a rerun resumes where it left off)
#   nkit-to-rvz-to-trrntzip run [--limit N] [--retry-failed]   run in this terminal
#
# Only discs that NKit verifies against the Redump DAT are zipped. Everything is recorded in
# $STATE_DIR/ledger.tsv, and archives already marked done (or failed) are skipped on reruns.
set -uo pipefail

# --- Configuration (override any of these with environment variables) ---------------------------
ORIGIN="${ORIGIN:-/run/media/LiamBox/Retreye1/1g1r/1G1R - Redump - Nintendo - Wii + WiiWare/wii}"
MIDDLE="${MIDDLE:-/run/media/system/Michael/nkit-2-rvz}"
DEST="${DEST:-/run/media/LiamBox/Alison/wii rvz-2-trrntzip}"
NKIT_DIR="${NKIT_DIR:-/var/home/LiamBox/Downloads/NKit_linux-x64_CLI_3.2.0}"
DAT="${DAT:-/var/home/LiamBox/repos/igir/nkit-2-rvz-2-trrntzip/Nintendo - Wii - Datfile (3780) (2026-06-15 03-13-28).dat}"
IGIR_DIR="${IGIR_DIR:-/var/home/LiamBox/repos/igir}"
FORMAT="${FORMAT:-rvz:zstd:19:128k:4}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/nkit-to-rvz-to-trrntzip}"
UNIT="nkit-to-rvz-to-trrntzip"
CONTAINER="${CONTAINER:-MyFedora}"

LEDGER="$STATE_DIR/ledger.tsv"
RUN_LOG="$STATE_DIR/run.log"
NKIT_LOGS="$STATE_DIR/nkit-logs"
WORK="$MIDDLE/.work"

# Run a command on the host, whether we're in the distrobox, the VS Code Flatpak, or the host
host() {
  if [[ -e /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null; then
    distrobox-host-exec "$@"
  elif [[ -e /.flatpak-info ]]; then
    flatpak-spawn --host "$@"
  else
    "$@"
  fi
}

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG"; }

ledger_add() { # archive, status, detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date '+%F %T')" >>"$LEDGER"
}

ledger_has() { # archive, statuses regex
  [[ -f "$LEDGER" ]] && awk -F'\t' -v a="$1" -v s="^($2)$" '$1 == a && $2 ~ s { f = 1 } END { exit !f }' "$LEDGER"
}

free_gb() { df -P --block-size=1G "$1" | awk 'NR == 2 { print $4 }'; }

# Check the zip is a TorrentZip holding exactly the given file, byte-for-byte (via size and CRC32)
verify_zip() { # zip, rvz
  python3 - "$1" "$2" <<'EOF'
import os, sys, zipfile, zlib
zip_path, rvz_path = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(zip_path)
entries = z.infolist()
if not z.comment.startswith(b"TORRENTZIPPED-"):
    sys.exit("not a TorrentZip")
if len(entries) != 1 or entries[0].filename != os.path.basename(rvz_path):
    sys.exit(f"unexpected entries: {[e.filename for e in entries]}")
if entries[0].file_size != os.path.getsize(rvz_path):
    sys.exit("size mismatch")
crc = 0
with open(rvz_path, "rb") as f:
    while chunk := f.read(1 << 24):
        crc = zlib.crc32(chunk, crc)
if crc != entries[0].CRC:
    sys.exit("CRC mismatch")
EOF
}

process_archive() { # archive path
  local archive="$1" name nkit_log rvzs rvz game zip
  name="$(basename "$archive")"
  nkit_log="$NKIT_LOGS/${name}.log"

  rm -rf "$WORK" && mkdir -p "$WORK"

  # 1. NKit: restore the original disc, convert it to RVZ, and verify it against the Redump DAT
  (cd "$NKIT_DIR" && ./nkit convert "$archive" --system wii --format "$FORMAT" \
    --verify datlookup --dat "$DAT" --dat-match --output "$WORK" --temp "$WORK") >"$nkit_log" 2>&1
  # NKit exits 0 even when verification fails, so check its reported result instead
  if ! grep -qE '^Verify +: VerifySuccess' "$nkit_log"; then
    local reason
    reason="$(grep -oE '^Verify +: Verify[A-Za-z]+' "$nkit_log" | tail -1 | sed -E 's/^Verify +: //')"
    rm -rf "$WORK"
    ledger_add "$name" failed "${reason:-no disc image processed} (see nkit-logs)"
    log "FAIL  $name: ${reason:-no disc image processed}"
    return
  fi

  mapfile -t rvzs < <(find "$WORK" -maxdepth 1 -type f -name '*.rvz')
  if [[ ${#rvzs[@]} -ne 1 ]]; then
    rm -rf "$WORK"
    ledger_add "$name" failed "expected 1 .rvz, found ${#rvzs[@]}"
    log "FAIL  $name: expected 1 .rvz, found ${#rvzs[@]}"
    return
  fi
  rvz="${rvzs[0]}"
  game="$(basename "$rvz" .rvz)"
  zip="$DEST/$game.zip"

  # Two archives can be the same Redump disc; keep the first one's zip. A zip that doesn't match
  # (e.g. left half-written by a stopped run) is replaced.
  if [[ -e "$zip" ]]; then
    if verify_zip "$zip" "$rvz" >/dev/null 2>&1; then
      rm -rf "$WORK"
      ledger_add "$name" done "$game.zip (already existed)"
      log "SKIP  $name: $game.zip already exists"
      return
    fi
    log "WARN  $name: replacing $game.zip, it doesn't match the verified .rvz"
    rm -f "$zip"
  fi

  # 2. igir: wrap the untouched .rvz in a TorrentZip
  if ! (cd "$IGIR_DIR" && npx --no-install tsx index.ts copy zip --input-raw-disc-images \
    --input "$WORK" --output "$DEST") >>"$nkit_log" 2>&1; then
    rm -rf "$WORK"
    rm -f "$zip"
    ledger_add "$name" failed "igir zip failed (see nkit-logs)"
    log "FAIL  $name: igir zip failed"
    return
  fi

  # 3. Check the zip, then delete the in-between .rvz
  local verify_error
  if ! verify_error="$(verify_zip "$zip" "$rvz" 2>&1)"; then
    rm -rf "$WORK"
    rm -f "$zip"
    ledger_add "$name" failed "zip check failed: $verify_error"
    log "FAIL  $name: zip check failed: $verify_error"
    return
  fi
  rm -rf "$WORK"
  ledger_add "$name" done "$game.zip"
  log "DONE  $name -> $game.zip"
}

cmd_run() {
  local limit=0 retry_failed=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --retry-failed) retry_failed=1; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done

  mkdir -p "$STATE_DIR" "$NKIT_LOGS"
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    echo "another run is already in progress" >&2
    exit 1
  fi

  # Never create these directories ourselves: if a drive isn't mounted, stop instead
  local dir
  for dir in "$ORIGIN" "$MIDDLE" "$DEST" "$NKIT_DIR"; do
    [[ -d "$dir" ]] || { log "ABORT  missing directory (is the drive mounted?): $dir"; exit 1; }
  done
  [[ -f "$DAT" ]] || { log "ABORT  missing DAT: $DAT"; exit 1; }
  [[ -x "$NKIT_DIR/nkit" ]] || { log "ABORT  missing NKit executable: $NKIT_DIR/nkit"; exit 1; }

  local skip_statuses='done|failed'
  [[ $retry_failed -eq 1 ]] && skip_statuses='done'

  local archives=() archive
  mapfile -t archives < <(find "$ORIGIN" -maxdepth 1 -type f \( -iname '*.7z' -o -iname '*.zip' \) | sort)
  log "START  ${#archives[@]} archives in origin, format $FORMAT"

  local processed=0 total_done=0 total_failed=0
  for archive in "${archives[@]}"; do
    if ledger_has "$(basename "$archive")" "$skip_statuses"; then
      continue
    fi
    if [[ $limit -gt 0 && $processed -ge $limit ]]; then
      break
    fi
    for dir in "$MIDDLE" "$DEST"; do
      if [[ $(free_gb "$dir") -lt $MIN_FREE_GB ]]; then
        log "ABORT  less than ${MIN_FREE_GB} GB free on $dir"
        exit 1
      fi
    done
    log "BEGIN $(basename "$archive")"
    process_archive "$archive"
    processed=$((processed + 1))
  done

  total_done="$(awk -F'\t' '$2 == "done"' "$LEDGER" 2>/dev/null | cut -f1 | sort -u | wc -l)"
  total_failed="$(awk -F'\t' '$2 == "failed"' "$LEDGER" 2>/dev/null | cut -f1 | sort -u | wc -l)"
  log "FINISH processed $processed this run; ledger: $total_done done, $total_failed failed (of ${#archives[@]})"
}

cmd_start() {
  host systemd-run --user --unit="$UNIT" --collect \
    --description="NKit -> RVZ -> TorrentZip" \
    systemd-inhibit --what=sleep:idle --who="$UNIT" --why="Converting Wii discs" \
    distrobox enter "$CONTAINER" -- bash -lc "$(printf '%q ' "$(realpath "$0")" run "$@")" ||
    return 1

  # Catch jobs that die straight away, instead of failing silently in the background
  sleep 5
  if [[ "$(host systemctl --user is-active "$UNIT" 2>/dev/null)" != active ]] &&
    ! grep -q FINISH <(tail -n 1 "$RUN_LOG" 2>/dev/null); then
    echo "The background job stopped right after starting. Last messages:" >&2
    host journalctl --user -u "$UNIT" --since "-1min" --no-pager -o cat 2>/dev/null |
      grep -v 'container exec' | tail -n 5 >&2
    return 1
  fi
  echo "Started in the background. Check on it with: $0 status"
}

cmd_status() {
  if [[ "$(host systemctl --user is-active "$UNIT" 2>/dev/null)" == active ]]; then
    echo "Background job: running (since $(host systemctl --user show "$UNIT" \
      --property=ActiveEnterTimestamp --value 2>/dev/null))"
  else
    echo "Background job: not running"
  fi
  if [[ -f "$LEDGER" ]]; then
    echo
    echo "Done:   $(awk -F'\t' '$2 == "done"' "$LEDGER" | cut -f1 | sort -u | wc -l)"
    echo "Failed: $(awk -F'\t' '$2 == "failed"' "$LEDGER" | cut -f1 | sort -u | wc -l)"
  fi
  [[ -f "$RUN_LOG" ]] && { echo; tail -n 5 "$RUN_LOG"; }
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  start) shift; cmd_start "$@" ;;
  status) cmd_status ;;
  log) tail -n "${2:-40}" -F "$RUN_LOG" ;;
  stop) host systemctl --user stop "$UNIT" && echo "Stopped. Run 'start' again to resume." ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
