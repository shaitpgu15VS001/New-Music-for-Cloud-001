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

# הערה לדיווח על צורת הקאבר — מוצאת ע"י square_cover ונקראת ב-report_quality.
# ריקה במצב full = הפלט נשאר זהה לפלט הקיים (ללא שינוי).
COVER_NOTE=""

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
  # חיתוך קאבר לריבוע והעשרת תגיות מאיטונס — אודיו בלבד, לא קטלני (רק הדיווח מושפע)
  if [ "$MODE" = "audio" ]; then
    if [ "${COVER_SHAPE:-full}" = "square" ]; then
      square_cover "$f" || true
    fi
    enrich_metadata "$f" || true
  fi
  report_quality "$f"
}

# -----------------------------------------------------------------------------
# חיתוך תמונת הקאבר לריבוע שווה-מרכז (COVER_SHAPE=square)
# שיטה (אומתה בניסוי מקומי 2026-11-02 על mp3+m4a): חילוץ התמונה המוטמעת
#   מהקובץ → חיתוך מרכז דרך ffmpeg → החזרה לאותה תגית דרך mutagen.
#   נבחר mutagen כי הוא כותב את התגית התקנית (APIC ל-mp3, covr ל-m4a)
#   בלי לערבב מחדש את קובץ האודיו; שיטת ffmpeg remux נדחתה בניסוי כי
#   במ4a היא לא כותבת את האטום covr (נשאר track תמונה לא תקני).
# לא קטלני: כל כשלון כאן משאיר את הקאבר המלבן ומדווח בכנות.
# -----------------------------------------------------------------------------
square_cover() {
  local f="$1"
  local img sq helper rc
  COVER_NOTE=" (מלבן — החיתוך נכשל)"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    log "⚠ חיתוך קאבר: ffmpeg חסר — התמונה נשארת מלבנית"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log "⚠ חיתוך קאבר: python3 חסר — התמונה נשארת מלבנית"
    return 1
  fi
  helper="$SCRIPT_DIR/embed-cover.py"
  if ! [ -f "$helper" ]; then
    log "⚠ חיתוך קאבר: embed-cover.py חסר — התמונה נשארת מלבנית"
    return 1
  fi
  # על Git-Bash (וינדוז) SCRIPT_DIR בצורה POSIX (/c/...) ש-python של וינדוז
  # לא מבין — cygpath -m מחזיר C:/... (אותו עיקרון כמו OUTPUT_DIR בשורה 48);
  # בלי cygpath (לינוקס/Mac) הנתיב נשאר כמו שהוא.
  command -v cygpath >/dev/null 2>&1 && helper="$(cygpath -m "$helper")"
  img="$OUTPUT_DIR/.cover-src.tmp.png"
  sq="$OUTPUT_DIR/.cover-sq.tmp.png"
  # -update 1 בחילוץ: תמונה אחת לקובץ (מונע שגיאת image2 sequence)
  ffmpeg -y -v error -i "$f" -map 0:v:0 -frames:v 1 -update 1 "$img" 2>/dev/null \
    && ffmpeg -y -v error -i "$img" -vf "crop=min(iw\,ih):min(iw\,ih)" "$sq" 2>/dev/null \
    && python3 "$helper" "$f" "$sq" >>"$LOG_FILE" 2>&1
  rc=$?
  rm -f "$img" "$sq"
  if [ "$rc" -eq 0 ]; then
    COVER_NOTE=" (ריבוע)"
    log "קאבר נחתך לריבוע שווה-מרכז"
    return 0
  fi
  log "⚠ חיתוך הקאבר נכשל — התמונה נשארת מלבנית (ההורדה עצמה תקינה)"
  return 1
}

# -----------------------------------------------------------------------------
# העשרת תגיות מ-iTunes (שלב 2) — לא קטלני; enrich-metadata.py משווה משך מול
# iTunes ורק בהתאמה (סף 10 שניות) כותב אלבום/תאריך שחרור/ז'אנר/רצועה/אמן.
# -----------------------------------------------------------------------------
enrich_metadata() {
  local f="$1" helper="$SCRIPT_DIR/enrich-metadata.py"
  command -v python3 >/dev/null 2>&1 && [ -f "$helper" ] || return 0
  command -v cygpath >/dev/null 2>&1 && helper="$(cygpath -m "$helper")"  # Git-Bash → python (עקרון square_cover)
  python3 "$helper" "$f" >>"$LOG_FILE" 2>&1 || log "⚠ העשרת מטא-דאטה לא הושלמה (ההורדה תקינה)"
}

# -----------------------------------------------------------------------------
# סיכום תגיות מוטמעות מהקובץ עצמו (מקור האמת, לא הלוג) — נקרא ע"י report_quality
# -----------------------------------------------------------------------------
meta_summary() {
  local tags="$1" out="" k
  for k in "title:כותרת" "artist:אמן" "date:תאריך" "album:אלבום" "genre:ז'אנר"; do
    echo "$tags" | grep -q "^TAG:${k%%:*}=" && out="$out, ${k#*:}"
  done
  [ -n "$out" ] && printf '✓ (%s)' "${out#, }" || printf 'אין'
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
    local br kbps="" src="" warn="" cover="אין" tags
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
    # תמונת קאבר מוטמעת: ffprobe מציגה אותה כזרם וידאו נפרד (attached pic)
    # גם ב-mp3 (ID3 APIC) וגם ב-m4a (covr) — אומת בתיעוד ffmpeg, 2026-11-02.
    # חוסר תמונה לא מפיל את האודيو — מדווחים את האמת במקום ✅ שווא.
    # COVER_NOTE מוסיף את צורת הקאבר אם בוצעה חיתוך (ריבוע / כשלון חיתוך);
    # במצב full ההערה ריקה והפלט נשאר מדויק כמו קודם.
    if ffprobe -v error -select_streams v -show_entries stream=codec_type \
         -of csv=p=0 "$f" 2>/dev/null | grep -q "video"; then
      cover="✓${COVER_NOTE:-}"
    fi
    tags=$(ffprobe -v error -show_entries format_tags -of default=nw=1 "$f" 2>/dev/null)
    echo "אודיו: ${kbps:-לאנמדור}${warn}; קאבר: $cover; מטא-דאטה: $(meta_summary "$tags")" > "$out"
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
    # תחילה בלי apt-get update — רשימות החבילות כבר קיימות בתמונת ה-runner;
    # רק אם ההתקנה נופלת — מעדכן רשימות ומתקין שוב (fallback מלא)
    (sudo apt-get install -y -qq ffmpeg) >>"$LOG_FILE" 2>&1 \
      || (sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg) >>"$LOG_FILE" 2>&1 \
      || true
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
