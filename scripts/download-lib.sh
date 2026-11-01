#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download-lib.sh — פונקציות עזר ל-download.sh
# נטען ע"י download.sh באמצעות source; אינו מופעל ישירות.
#
# מכיל: לוגינג, שכבת נפילה cobalt, אימות פלט, דיווח איכות (ffprobe),
#        והתקנת ffmpeg.
# -----------------------------------------------------------------------------

# רשימת instancות cobalt לבדיקה — ללא טוקן/Turnstile (לא פעילות נכון ל-2026-10-30)
COBALT_HOSTS=(
  "https://co.otomir23.me"
)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
fail() { log "✖ $*"; exit 1; }

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
# בלי בדיקת סיומת — קובץ mp4 הורדה נחשב ל"הצלחה" של מצב אודיו (באג מ-2026-11-01)
# -----------------------------------------------------------------------------
verify_output() {
  local -a exts
  local f e
  if [ "$MODE" = "audio" ]; then
    # רק סיומות אודיו מדויקות: mp3 (QUALITY מספרי) או m4a (אחרת).
    # webm/mkv אסור כאן — עלולים להיות וידאו שנותר מ-fallback "b" (באג ה-✅ השווא)
    exts=(mp3 m4a)
  else
    exts=(mp4 mkv webm)
  fi
  f=""
  for e in "${exts[@]}"; do
    f=$(find "$OUTPUT_DIR" -type f -size +1k -mmin -30 ! -name "*.log" ! -name "quality.txt" -iname "*.$e" 2>/dev/null | head -1)
    [ -n "$f" ] && break
  done
  if [ -z "$f" ]; then
    fail "לא נמצא קובץ פלט תקין (סיומות מצופות: ${exts[*]})"
  fi
  # דגל הצלחה — מקור האמת היחיד של ה-workflow (לא "קיים קובץ")
  : > "$OUTPUT_DIR/.download-ok"
  log "✔ הצליח! קובץ: $f ($(du -h "$f" | cut -f1))"
  report_quality "$f"
}

# -----------------------------------------------------------------------------
# דיווח איכות אמיתי: ffprobe על הקובץ שהורד בפועל
# כותב downloads/quality.txt שה-workflow מציג ב-Summary — כדי שהמשתמש יראה
# את האיכות האמיתית ולא רק את המבוקשת (באג מ-2026-11-01: ביקשו 1080 ירד 360)
# -----------------------------------------------------------------------------
report_quality() {
  local f="$1"
  local out="$OUTPUT_DIR/quality.txt"
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "איכות לא נבדקה (ffprobe חסר)" > "$out"
    return 0
  fi
  if [ "$MODE" = "audio" ]; then
    local br kbps="" src="" warn=""
    br=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
      -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
    [ -n "$br" ] && kbps=$(awk -v b="$br" 'BEGIN{printf "%.0f kbps", b/1000}')
    # מקור האודיו מהלוג: פורמטים 17/18/22 הם מסרט משותף — איכות מקור נמוכה.
    # פורמטים נפרדים (140, 251, או צירוף X+Y) הם סטרימינג אודיו תקין.
    src=$(grep -oE 'Downloading [0-9]+ format\(s\): [0-9+]+' \
      "$OUTPUT_DIR/ytdlp-verbose.log" 2>/dev/null | tail -1 | sed 's/.*: //')
    case "$src" in
      17|18|22) warn=" — המקור פורמט $src (אודיו מתוך סרט, לא סטרימינג אודיו)" ;;
    esac
    echo "אודיו: ${kbps:-לאנמדור}${warn}" > "$out"
    log "איכות בפועל: $(cat "$out")"
  else
    local res
    res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
      -of csv=s=x:p=0 "$f" 2>/dev/null | head -1)
    if [ -n "$res" ]; then
      local h="${res##*x}"
      if echo "$QUALITY" | grep -qE '^[0-9]+$' && [ "$h" -lt "$QUALITY" ]; then
        echo "וידאו: $res — נמוך מהמבוקש (${QUALITY}p)" > "$out"
        log "⚠ איכות בפועל $res — נמוך מ-${QUALITY} המבוקש"
      else
        echo "וידאו: $res" > "$out"
        log "איכות בפועל: $res"
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# בדיקת ffmpeg — חובה להמרת אודיו ולמיזוג וידאו+אודיו
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
