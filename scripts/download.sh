#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download.sh — הורדה מיוטיוב / יוטיוב מיוזיק בשלוש שכבות גיבוי
#
# שימוש:
#   ./download.sh <url> [video|audio] [איכות: מספר או max, ברירת מחדל 1080]
#
# שכבה 1: yt-dlp + PO Token provider (bgutil) — ללא חשבון Google
# שכבה 1b: yt-dlp עם clients שאינם דורשים PO Token כלל
# שכבה 2: cobalt API ציבורי — אם השכבות הקודמות נכשלות
#
# הקבצים נשמרים בתיקיית ./downloads (ניתן לשנות במשתנה OUTPUT_DIR)
# -----------------------------------------------------------------------------
set -u -o pipefail

URL="${1:?שימוש: download.sh <url> [video|audio] [איכות]}"
MODE="${2:-video}"          # video | audio
QUALITY="${3:-1080}"        # מספר (1080, 720...) או max
OUTPUT_DIR="${OUTPUT_DIR:-downloads}"

# נרמול קישורי youtube: /shorts/ ו-music.youtube.com הולכים לנתיבים שונים ב-extractor
# paths שנחסמים לעתים קרובות יותר מ-IP של דאטה סנטר — ממירים לצורת watch
if echo "$URL" | grep -qE "youtube\.com/shorts/"; then
  VID=$(echo "$URL" | grep -oE "shorts/[A-Za-z0-9_-]+" | cut -d/ -f2)
  [ -n "$VID" ] && URL="https://www.youtube.com/watch?v=$VID"
fi
if echo "$URL" | grep -q "music.youtube.com"; then
  VID=$(echo "$URL" | grep -oE "v=[A-Za-z0-9_-]+" | cut -d= -f2)
  [ -n "$VID" ] && URL="https://www.youtube.com/watch?v=$VID"
fi

# נתיב מוחלט — קריטי: השרת נפתח אחרי cd לתיקייה אחרת
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
LOG_FILE="$OUTPUT_DIR/download.log"

# רשימת instancות cobalt לבדיקה — ללא טוקן/Turnstile
COBALT_HOSTS=(
  "https://co.otomir23.me"
)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
fail() { log "✖ $*"; exit 1; }

# -----------------------------------------------------------------------------
# שכבה 1 — yt-dlp (+ PO Token אם השרת זמין)
# -----------------------------------------------------------------------------
try_ytdlp() {
  log "שכבה 1: yt-dlp + PO Token provider"

  python3 -m pip install --quiet --upgrade "yt-dlp" "bgutil-ytdlp-pot-provider" >>"$LOG_FILE" 2>&1 \
    || { log "התקנת yt-dlp / bgutil plugin נכשלה"; return 1; }

  start_po_server

  local out_pattern="$OUTPUT_DIR/%(title)s [%(id)s].%(ext)s"
  local -a extra=()
  if [ "$MODE" = "audio" ]; then
    extra+=(-x --audio-format mp3 --audio-quality 0)
  elif [ "$QUALITY" = "max" ]; then
    # "max" אינו ערך תקין ל-filter של yt-dlp — משמיטים את סינון הגובה
    extra+=(-f "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b" --merge-output-format mp4)
  else
    extra+=(-f "bv*[height<=${QUALITY}][ext=mp4]+ba[ext=m4a]/b[height<=${QUALITY}]/b" --merge-output-format mp4)
  fi

  # ניסיון 1: mweb + PO Token — עם verbose כדי לראות אם ה-plug-in נטען
  # --js-runtimes node: yt-dlp אינו מפעיל אוטומטית node לפתרון JS challenges,
  # וללא פתרון אתגרים YouTube חוסם ("not a bot")
  if [ "${PO_SERVER_UP:-0}" = "1" ]; then
    local pot_client
    for pot_client in mweb web; do
      log "מנסה yt-dlp עם $pot_client + PO Token + node JS runtime"
      if yt-dlp -v \
          --js-runtimes node \
          --extractor-args "youtube:player_client=$pot_client" \
          --sleep-requests 2 \
          --retries 3 \
          "${extra[@]}" \
          -o "$out_pattern" \
          --no-playlist \
          "$URL" >"$OUTPUT_DIR/ytdlp-verbose.log" 2>&1; then
        tail -5 "$OUTPUT_DIR/ytdlp-verbose.log" | tee -a "$LOG_FILE"
        return 0
      fi
      log "  ✖ $pot_client+PO Token: $(grep -m1 '^ERROR' "$OUTPUT_DIR/ytdlp-verbose.log" 2>/dev/null | cut -c1-120)"
      sleep 10
    done
    log "שורות פוט-טוקן אחרונות מהלוג:"
    grep -iE "\[pot|bgutil|potoken|po token|provider|jsc" "$OUTPUT_DIR/ytdlp-verbose.log" | tail -10 | tee -a "$LOG_FILE"
  fi

  # ניסיון 2: clients שאינם דורשים PO Token — כל אחד בנפרד, עם המתנה
  # ביניהם: 3 מטריצות במקביל מאותה רשת עלולות להפעיל הגנת rate-limit של YouTube
  local pass client
  for pass in 1 2; do
    for client in tv_simply android_vr web_embedded; do
      log "מנסה yt-dlp עם client: $client (סבב $pass)"
      sleep 15
      if yt-dlp \
          --js-runtimes node \
          --extractor-args "youtube:player_client=$client" \
          --sleep-requests 3 \
          --retries 3 \
          "${extra[@]}" \
          -o "$out_pattern" \
          --no-playlist \
          "$URL" >"$OUTPUT_DIR/ytdlp-verbose.log" 2>&1; then
        log "✔ client $client הצליח"
        tail -3 "$OUTPUT_DIR/ytdlp-verbose.log" | tee -a "$LOG_FILE"
        return 0
      fi
      log "  ✖ $client: $(grep -m1 '^ERROR' "$OUTPUT_DIR/ytdlp-verbose.log" 2>/dev/null | cut -c1-120)"
    done
  done

  log "yt-dlp נכשל בכל הניסיונות"
  return 1
}

# -----------------------------------------------------------------------------
# הקמת שרת PO Token — best effort
# -----------------------------------------------------------------------------
start_po_server() {
  PO_SERVER_UP=0
  local bgutil_dir="$HOME/bgutil-ytdlp-pot-provider"
  local server_log="$OUTPUT_DIR/download.log.bgutil"

  if [ ! -d "$bgutil_dir" ]; then
    git clone --depth 1 --single-branch --branch 2.0.2 \
      https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git "$bgutil_dir" >>"$LOG_FILE" 2>&1 \
      || { log "git clone של bgutil נכשל — אמשיך בלי שרת טוקנים"; return 0; }
  fi

  log "מתקין ומקompil את שרת ה-PO Token (יכול להימשך כדקה)..."
  (cd "$bgutil_dir/server" && npm ci --no-audit --no-fund && npx tsc) >>"$LOG_FILE" 2>&1 \
    || { log "npm ci / tsc של bgutil נכשל — אמשיך בלי שרת טוקנים (פרטים ב-LOG)"; return 0; }

  # הפעלה — לוג בנתיב מוחלט, cd קורה בתת-תהליך נפרד מההפניה
  (
    cd "$bgutil_dir/server" || exit 1
    node build/main.js >"$server_log" 2>&1 &
    echo $! > /tmp/bgutil.pid
  )
  local i
  for i in $(seq 1 12); do
    sleep 5
    if curl -s --max-time 5 http://127.0.0.1:4416/ping 2>/dev/null | grep -q "server_uptime"; then
      PO_SERVER_UP=1
      log "שרת PO Token פעיל ✓"
      return 0
    fi
  done
  log "שרת PO Token לא עלה — אמשיך בלי טוקנים"
  log "יומן השרת: $(tail -5 "$server_log" 2>/dev/null | tr '\n' ' ')"
}

# -----------------------------------------------------------------------------
# שכבה 2 — cobalt API
# -----------------------------------------------------------------------------
try_cobalt() {
  log "שכבה 2: cobalt API"
  # ל- cobalt ערכי downloadMode הם auto/audio/mute — "video" אינו ערך חוקי
  local body
  if [ "$MODE" = "audio" ]; then
    body="{\"url\":\"$URL\",\"downloadMode\":\"audio\",\"audioFormat\":\"mp3\",\"audioBitrate\":\"320\"}"
  elif [ "$QUALITY" = "max" ]; then
    body="{\"url\":\"$URL\",\"downloadMode\":\"auto\",\"videoQuality\":\"max\"}"
  else
    body="{\"url\":\"$URL\",\"downloadMode\":\"auto\",\"videoQuality\":\"$QUALITY\"}"
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
