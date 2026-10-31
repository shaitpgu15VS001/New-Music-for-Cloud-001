#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download.sh — הורדה מיוטיוב / יוטיוב מיוזיק בשיטת client-first
# תוכנן לעבודה מ-IPs של Data Center / GitHub Actions ללא PO Token
#
# שימוש:
#   ./download.sh <url> [video|audio] [איכות: מספר או max, ברירת מחדל 1080]
#
# אסטרטגיה: ניסיון לקוחות yt-dlp שמאומןים לעבוד מ-DC IPs
# 1. android,web — לקוחות עם זיהוי bot חלש, עובדים מ-DC IPs ללא PO Token
# 2. שאר clients כאלטרנטיבה
# שכבת נפילה: cobalt API — אם כל ה-clients כשלו
#
# הקבצים נשמרים בתיקיית ./downloads (ניתן לשנות במשתנה OUTPUT_DIR)
# -----------------------------------------------------------------------------
set -u -o pipefail

URL="${1:?שימוש: download.sh <url> [video|audio] [איכות]}"
MODE="${2:-video}"          # video | audio
QUALITY="${3:-1080}"        # מספר (1080, 720...) או max
OUTPUT_DIR="${OUTPUT_DIR:-downloads}"

# נרמול קישורי youtube: /shorts/ ו-music.youtube.com הולכים לנתיבים שונים ב-extractor
# paths שנחסמים לעתים קרובות יותר מ-IP של Data Center — ממירים לצורת watch
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
# שכבת yt-dlp עם player_client=android,web (מאומן ל-DC IPs)
# -----------------------------------------------------------------------------
try_android_web() {
  log "שכבת yt-dlp: player_client=android,web (מאומן ל-DC IPs, ללא PO Token)"

  python3 -m pip install --quiet --upgrade "yt-dlp" >>"$LOG_FILE" 2>&1 \
    || { log "התקנת yt-dlp נכשלה"; return 1; }

  local out_pattern="$OUTPUT_DIR/%(title)s [%(id)s].%(ext)s"
  local -a extra=()
  if [ "$MODE" = "audio" ]; then
    # עבור אודיו: android client + best audio format
    extra+=(-x --audio-format m4a --audio-quality 0)
    # android client תומך ב-m4a ב-DC IPs
    extra+=(-f "bv*+ba/m4a/b" --merge-output-format m4a)
  elif [ "$QUALITY" = "max" ]; then
    # "max" — משמיטים סינון גובה, מורידים את הזמין ביותר
    extra+=(-f "bv*+ba/b" --merge-output-format mp4)
  else
    extra+=(-f "bv*[height<=${QUALITY}][ext=mp4]+ba[ext=m4a]/b[height<=${QUALITY}]/b" --merge-output-format mp4)
  fi

  # android + web — השילוב שמאומן לעבוד מ-Datacenter IPs
  # android: זיהוי bot חלש, עובד מ-DC IPs
  # web: פותח פורמטים נוספים אך דורש התאמה
  # --force-ipv4: מאלץ שימוש ב-IPv4 בלבד, לעקיפת חסימות IP של DC
  local -a clients=("android" "web_embedded" "web")
  local pass client

  for pass in 1 2; do
    for client in "${clients[@]}"; do
      log "מנסה yt-dlp עם client: $client (סבב $pass)"
      sleep 20  # הארכה משמעותית: YouTube מאטל DC IPs בין נסיונות

      if yt-dlp \
          --js-runtimes node \
          --extractor-args "youtube:player_client=$client" \
          --sleep-requests 5 \
          --retries 5 \
          --force-ipv4 \
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

  log "yt-dlp נכשל בכל נסיונות client android/web"
  return 1
}

# -----------------------------------------------------------------------------
# שכבת נפילה: cobalt API
# -----------------------------------------------------------------------------
try_cobalt() {
  log "שכבת 2: cobalt API"
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

# ניסיון ראשון: yt-dlp עם android/web client (ללא PO Token, מותאם ל-DC IPs)
try_android_web || try_cobalt || fail "כל השכבות נכשלו"

verify_output

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
