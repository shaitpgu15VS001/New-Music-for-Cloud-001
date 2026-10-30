#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download.sh — הורדה מיוטיוב / יוטיוב מיוזיק בשתי שכבות גיבוי
#
# שימוש:
#   ./download.sh <url> [video|audio] [איכות: מספר או max, ברירת מחדל 1080]
#
# שכבה 1: yt-dlp + PO Token provider (bgutil) — ללא חשבון Google
# שכבה 2: cobalt API ציבורי — אם שכבה 1 נכשלת
#
# הקובץ נשמרת בתיקיית ./downloads (ניתן לשנות במשתנה OUTPUT_DIR)
# -----------------------------------------------------------------------------
set -u -o pipefail

URL="${1:?שימוש: download.sh <url> [video|audio] [איכות]}"
MODE="${2:-video}"          # video | audio
QUALITY="${3:-1080}"        # מספר (1080, 720...) או max
OUTPUT_DIR="${OUTPUT_DIR:-downloads}"

# רשימת instancות cobalt לבדיקה — ללא טוקן/Turnstile
COBALT_HOSTS=(
  "https://co.otomir23.me"
)

mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/download.log"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
fail() { log "✖ $*"; exit 1; }

# -----------------------------------------------------------------------------
# שכבה 1 — yt-dlp + PO Token
# -----------------------------------------------------------------------------
try_ytdlp() {
  log "שכבה 1: yt-dlp + PO Token provider"

  python3 -m pip install --quiet --upgrade "yt-dlp[default]" >/dev/null 2>&1 \
    || { log "התקנת yt-dlp נכשלה"; return 1; }

  # bgutil PO Token provider — יוצר טוקן ללא חשבון Google
  local bgutil_dir="$HOME/bgutil-ytdlp-pot-provider"
  if [ ! -d "$bgutil_dir" ]; then
    git clone --depth 1 \
      https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git "$bgutil_dir" >/dev/null 2>&1 \
      || { log "git clone של bgutil נכשל"; return 1; }
  fi
  (cd "$bgutil_dir/server" && npm install --silent >/dev/null 2>&1 && npm run build --silent >/dev/null 2>&1) \
    || { log "npm install/build של bgutil נכשל"; return 1; }

  # הפעלת שרת ה-PO Token ברקע
  (cd "$bgutil_dir/server" && node build.js >"$LOG_FILE.bgutil" 2>&1 &
   echo $! > /tmp/bgutil.pid)
  sleep 8
  if ! curl -s --max-time 5 http://127.0.0.1:4416/ping | grep -q ok; then
    log "שרת PO Token לא עלה על פורט 4416"
    cat "$LOG_FILE.bgutil" 2>/dev/null | tail -5
    return 1
  fi
  log "שרת PO Token פעיל ✓"

  local out_pattern="$OUTPUT_DIR/%(title)s [%(id)s].%(ext)s"
  local -a extra=()
  if [ "$MODE" = "audio" ]; then
    extra+=(-x --audio-format mp3 --audio-quality 0)
  else
    extra+=(-f "bv*[height<=${QUALITY}][ext=mp4]+ba[ext=m4a]/b[height<=${QUALITY}]/b" --merge-output-format mp4)
  fi

  if yt-dlp \
      --extractor-args "youtube:player_client=mweb" \
      --sleep-requests 2 \
      --retries 3 \
      "${extra[@]}" \
      -o "$out_pattern" \
      --no-playlist \
      "$URL" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  fi
  log "yt-dlp נכשל"
  return 1
}

# -----------------------------------------------------------------------------
# שכבה 2 — cobalt API
# -----------------------------------------------------------------------------
try_cobalt() {
  log "שכבה 2: cobalt API"
  local body
  if [ "$MODE" = "audio" ]; then
    body="{\"url\":\"$URL\",\"downloadMode\":\"audio\",\"audioFormat\":\"mp3\",\"audioBitrate\":\"320\"}"
  else
    body="{\"url\":\"$URL\",\"downloadMode\":\"video\",\"videoQuality\":\"$QUALITY\"}"
  fi
  local host
  for host in "${COBALT_HOSTS[@]}"; do
    log "מנסה $host"
    local resp
    resp=$(curl -s --max-time 30 -X POST "$host/" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -d "$body")

    local status url
    status=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [ "$status" != "tunnel" ] && [ "$status" != "redirect" ]; then
      log "  ✖ תשובה: ${resp:0:200}"
      continue
    fi
    url=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['url'])")
    local fname
    fname=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('filename','video.mp4'))")

    if curl -sL --max-time 300 -o "$OUTPUT_DIR/$fname" "$url" && [ -s "$OUTPUT_DIR/$fname" ]; then
      log "  ✔ הורד: $fname ($(du -h "$OUTPUT_DIR/$fname" | cut -f1))"
      return 0
    fi
    log "  ✖ הורדה מה-tunnel נכשלה"
  done
  return 1
}

# -----------------------------------------------------------------------------
# בדיקת תקינות: הקובץ לא ריק וגדול מ-1KB
# -----------------------------------------------------------------------------
verify_output() {
  local f
  # קובץ חדש (אחרי התחלת הריצה) בגודל מעל 1KB שאינו לוג
  f=$(find "$OUTPUT_DIR" -type f -size +1k -mmin -30 ! -name "*.log" | head -1)
  if [ -z "$f" ]; then
    fail "לא נמצא קובץ פלט תקין"
  fi
  log "✔ הצליח! קובץ: $f ($(du -h "$f" | cut -f1))"
}

# -----------------------------------------------------------------------------
# ריצה
# -----------------------------------------------------------------------------
log "מתחיל: $URL | מצב=$MODE | איכות=$QUALITY"

# ניקוי שרת ה-PO Token בסיום
trap '[ -f /tmp/bgutil.pid ] && kill "$(cat /tmp/bgutil.pid)" 2>/dev/null' EXIT

try_ytdlp || try_cobalt || fail "כל השכבות נכשלו"
verify_output
