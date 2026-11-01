#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download.sh — הורדה מיוטיוב / יוטיוב מיוזיק בשיטת client-first
# תוכנן לעבודה מ-IPs של Data Center / GitHub Actions ללא PO Token
#
# שימוש:
#   ./download.sh <url> [video|audio] [איכות: מספר או max, ברירת מחדל 1080]
#
# משתנה סביבה:
#   YTDLP_PROXY — פרוקסי אופציונלי שכל תעבורת yt-dlp תעבור דרכו
#                 לדוגמה: http://127.0.0.1:1080 ( של Cloudflare WARP)
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
# פרוקסי אופציונלי — אם מוגדר, yt-dlp יעבוד דרכו (למשל WARP בתוך ה-runner)
PROXY="${YTDLP_PROXY:-}"

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
    # אודיו בלבד: --merge-output-format הוא ערך מכולה (mp4/mkv/webm) בלבד
    # ודחיית m4a ממנו גרמה לכשלון מוחלט בעבר — ההמרה נעשית ע"י ffmpeg אחרי ההורדה.
    # QUALITY عددית וסבירה (עד 512) = ביטрейט mp3 מבוקש, אחרת m4a.
    if echo "$QUALITY" | grep -qE '^[0-9]+$' && [ "$QUALITY" -le 512 ]; then
      extra+=(-f "ba/b" -x --audio-format mp3 --audio-quality "${QUALITY}K")
    else
      extra+=(-f "ba/b" -x --audio-format m4a)
    fi
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
  local -a proxy_args=()
  [ -n "$PROXY" ] && { proxy_args=(--proxy "$PROXY"); log "yt-dlp עובד דרך פרוקסי: $PROXY"; }
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
          "${proxy_args[@]}" \
          "${extra[@]}" \
          -o "$out_pattern" \
          --no-playlist \
          "$URL" >"$OUTPUT_DIR/ytdlp-verbose.log" 2>&1; then
        log "✔ client $client הצליח"
        tail -3 "$OUTPUT_DIR/ytdlp-verbose.log" | tee -a "$LOG_FILE"
        return 0
      fi
      log "  ✖ $client: $(grep -m1 -iE '^(ERROR|yt-dlp: error)' "$OUTPUT_DIR/ytdlp-verbose.log" 2>/dev/null | cut -c1-140)"
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
# בדיקת תקינות: הקובץ קיים, גדול מ-1KB, ותואם את הסיומת הצפויה למצב
# بدون בדיקת סיומת — קובץ mp4 הורדה נחשב ל"הצלחה" של מצב אודיו (באג מ-2026-11-01)
# -----------------------------------------------------------------------------
verify_output() {
  local -a exts
  local f e
  if [ "$MODE" = "audio" ]; then
    # רק סיומות אודיו מדויקות: mp3 (_QUALITY מספרי) או m4a (אחרת).
    # webm/mkv אסור כאן — עלולים להיות وידאו שנותר מ-fallback "b" (באג ה-✅ השווא)
    exts=(mp3 m4a)
  else
    exts=(mp4 mkv webm)
  fi
  f=""
  for e in "${exts[@]}"; do
    f=$(find "$OUTPUT_DIR" -type f -size +1k -mmin -30 ! -name "*.log" -iname "*.$e" 2>/dev/null | head -1)
    [ -n "$f" ] && break
  done
  if [ -z "$f" ]; then
    fail "לא נמצא קובץ פלט תקין (סיומות מצופות: ${exts[*]})"
  fi
  # דגל הצלחה — מקור האמת היחיד של ה-workflow (לא "קיים קובץ")
  : > "$OUTPUT_DIR/.download-ok"
  log "✔ הצליח! קובץ: $f ($(du -h "$f" | cut -f1))"
}

# -----------------------------------------------------------------------------
# בדיקת ffmpeg — חובה להמרת אודיו ולמיזוג וידאו+nפרד
# runner עלול לא לכלול אותו; התקנה עצמית אם חסר
# -----------------------------------------------------------------------------
ensure_ffmpeg() {
  local chk="$OUTPUT_DIR/ffmpeg-check.log"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -version 2>/dev/null | head -3 > "$chk"
    log "ffmpeg: $(head -1 "$chk" | cut -c1-70)"
    return 0
  fi
  echo "ffmpeg לא היה מותקן ב-runner" > "$chk"
  log "⚠ ffmpeg לא נמצא — מתקין..."
  if command -v apt-get >/dev/null 2>&1; then
    (sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg) >>"$LOG_FILE" 2>&1 || true
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -version 2>/dev/null | head -3 >> "$chk"
    log "✔ ffmpeg הותקן בהצלחה"
    return 0
  fi
  echo "ההתקנה נכשלה — פורמטים שדורשים המרה/מיזוג ייכשלו" >> "$chk"
  log "⚠ ffmpeg עדיין חסר — פורמטים שדורשים המרה/מיזוג עלולים להיכשל"
  return 0
}

# -----------------------------------------------------------------------------
# ריצה
# -----------------------------------------------------------------------------
log "מתחיל: $URL | מצב=$MODE | איכות=$QUALITY"

# וידוא ש-ffmpeg זמין (המרת אודיו, מיזוג וידאו+nפרד)
ensure_ffmpeg

# ניסיון ראשון: yt-dlp עם android/web client (ללא PO Token, מותאם ל-DC IPs)
try_android_web || try_cobalt || fail "כל השכבות נכשלו"

verify_output

