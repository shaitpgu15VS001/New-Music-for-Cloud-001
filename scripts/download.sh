#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# download.sh — הורדה מיוטיוב / יוטיוב מיוזיק בשיטת client-first
# תוכנן לעבודה מ-IPs של Data Center / GitHub Actions ללא PO Token
#
# שימוש:
#   ./download.sh <url> [video|audio] [איכות: מספר או max, ברירת מחדל 1080]
#                 [צורת קאבר: full|square, ברירת מחדל full]
#   צורת הקאבר חלה על אודיו בלבד: full = התמונה המלאה כפי שהיא ביוטיוב
#   (מלבן), square = חיתוך לריבוע שווה-מרכז. ערך לא תקין נופל ל-full
#   עם אזהרה (לא מפיל את ההורדה).
#
# משתנה סביבה:
#   YTDLP_PROXY — פרוקסי אופציונלי שכל תעבורת yt-dlp תעבור דרכו
#                 לדוגמה: http://127.0.0.1:1080 (של Cloudflare WARP)
#
# אסטרטגיה: שני סבבי ניסיון לכל client
# סבב א' — איכות מלאה: דורש רזולוציה סבירה (לפחות 720p לבקשות 1080+)
#          או אודיו נפרד (ba) — לא מתפשר בשקט על 360p
# סבב ב' — התאמה: הטוב ביותר הזמין, כדי לא לחסום סרטים שאין בהם איכות גבוהה
# לקוחות (בסדר ניסיון): visionos,web — ברירת המחדל של yt-dlp, עוקפים SABR;
#   tv,ios,android,web_embedded — מפלטים (tv שבור כעת #17389, android נותן 360p)
# שכבת נפילה: cobalt API — אם כל ה-clients כשלו
#
# הקבצים נשמרים בתיקיית ./downloads (ניתן לשנות במשתנה OUTPUT_DIR)
# -----------------------------------------------------------------------------
set -u -o pipefail

URL="${1:?שימוש: download.sh <url> [video|audio] [איכות]}"
MODE="${2:-video}"          # video | audio
QUALITY="${3:-1080}"        # מספר (1080, 720...) או max
COVER_SHAPE="${4:-full}"    # full | square — צורת תמונת הקאבר באודיו
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
# על Git-Bash (וינדוז): pwd מחזיר צורה POSIX (/c/...) ש-yt-dlp ו-ffprobe
# של וינדוז לא מבינים — הקבצים נוחתים בתיקייה שגוייה ואז מתקבל "לא נמצא
# קובץ פלט" (אותר ותוקן 2026-11-02). cygpath -m מחזיר C:/... שכולם מבינים;
# בלי cygpath (לינוקס/Mac) — נופלים ל-pwd כרגיל, ללא שינוי התנהגות.
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && { command -v cygpath >/dev/null 2>&1 && cygpath -m "$PWD" || pwd; })"
LOG_FILE="$OUTPUT_DIR/download.log"

# טוען פונקציות עזר (cobalt, אימות, דיווח איכות, ffmpeg)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=download-lib.sh
source "$SCRIPT_DIR/download-lib.sh"

# אימות צורת הקאבר — ערך לא תקין לא מפיל את ההורדה, נופלים ל-full
case "$COVER_SHAPE" in
  full|square) ;;
  *)
    log "⚠ צורת קאבר לא תקינה: '$COVER_SHAPE' — משתמש ב-full (מלבן)"
    COVER_SHAPE=full
    ;;
esac

# -----------------------------------------------------------------------------
# שכבת yt-dlp עם player_client — visionos,web ראשונים (ברירת המחדל, עוקפים SABR)
# -----------------------------------------------------------------------------
try_android_web() {
  log "שכבת yt-dlp: player_client=visionos,web,tv,ios,android,web_embedded (visionos עוקף SABR)"

  # mutagen — נחוץ ל--embed-thumbnail ב-m4a; pip install yt-dlp לא מתקין אותה
  # (היא רק באופציה הנוספת default — אומת ב-PyPI, 2026-11-02). לmp3 לא צריך
  # אותה — yt-dlp מטמיע את התמונה דרך ffmpeg שגם ככה מותקן (ensure_ffmpeg).
  python3 -m pip install --quiet --upgrade --disable-pip-version-check "yt-dlp" mutagen >>"$LOG_FILE" 2>&1 \
    || { log "התקנת yt-dlp נכשלה"; return 1; }

  # השם מכיל את הכותרת בלבד — מזהה הסרטון עבר משם הקובץ אל תוך תגית
  # "הערות" (ראה את blok meta_args למטה). אימות היציאה מאתר לפי סיומת,
  # לא לפי שם — לכן ההסרה לא שוברת את verify_output (אומת 2026-11-03).
  local out_pattern="$OUTPUT_DIR/%(title)s.%(ext)s"

  # --- בניית פורמטים: סבב איכות מלאה + סבב התאמה --------------------------
  # הסיבה: הלקוחות android/web/web_embedded לפעמים מחזירים רק פורמט 18 (360p)
  # של יוטיוב — וה-selector הישן קיבל אותו בשקט כי 360 <= 1080.
  local -a extra_strict=() extra_lenient=()
  local skip_lenient=0

  # --- מטא-דאטה (שלב 1, אומת בניסוי 2026-11-02) ----------------------------
  # --embed-metadata: yt-dlp כותב דרך ffmpeg כותרת, תאריך, תיאור, קישור
  #   למקור, אמן, ז'אנר, אלבום ושם שיר — מידע שנשאב מיוטיוב ללא מפתח.
  #   אומת: FFmpegMetadata רוץ לפני EmbedThumbnail בסדר ה-post-processors,
  #   ו-9/9 מקרי קצה קשים (עברית, אימוג'י, 5000 תווים) עברו ללא שגיאה.
  local -a meta_args=(--embed-metadata)
  # מזהה הסרטון: במקום שם הקובץ — בתגית "הערות", בצורה "מזהה | קישור למקור".
  # --parse-metadata יוצר שדה-ביניים ששמו meta_comment; yt-dlp הופך כל שדה
  # שמתחיל ב-meta_ לתגית מותאמת (FFmpegMetadataPP, ffmpeg.py 765-769).
  # אומת בניסוי 2026-11-03: נרשם כ-TXXX ב-mp3, ©cmt ב-m4a/mp4, וב-mkv/webm.
  # נבחרה "הערות" כי היא התגית היחידה ששרדה בכל הפורמטים (ניסוי F1-F3).
  meta_args+=(--parse-metadata "%(id)s | %(webpage_url)s:(?P<meta_comment>.+)")
  if [ "$MODE" = "audio" ]; then
    # QUALITY מספרית וסבירה (עד 512) = ביטרעט mp3 מבוקש, אחרת m4a.
    # סבב א': אודיו נפרד (ba) בלבד — לא נשחק מסרט 360p.
    # סבב ב': ba/b — נפילה למסך משותף אם אין אודיו נפרד כלל.
    # --embed-thumbnail: מטמיע את תמונת הקאבר של השיר בתוך קובץ האודיו.
    #   yt-dlp בוחר את התמונה הגבוהה ביותר הזמינה; אם שליפתה נכשלת — ההורדה
    #   ממשיכה בלעדיה (לא קטלני — אומת בקוד yt-dlp, 2026-11-02).
    if echo "$QUALITY" | grep -qE '^[0-9]+$' && [ "$QUALITY" -le 512 ]; then
      # mp3 בלבד: שלב הטמעת התמונה מאלץ id3v2.3 ומקצר את התאריך מ-20230402
      # ל-2023. id3v2_version 4 עוקף זאת — אומת בניסוי: התאריך המלא נשמר,
      # הקאבר מוטמע, וגם ID3v1 הישן לוינדוז נשאר.
      meta_args+=(--postprocessor-args "EmbedThumbnail:-id3v2_version 4")
      extra_strict=(-f "ba" -x --audio-format mp3 --audio-quality "${QUALITY}K" --embed-thumbnail "${meta_args[@]}")
      extra_lenient=(-f "ba/b" -x --audio-format mp3 --audio-quality "${QUALITY}K" --embed-thumbnail "${meta_args[@]}")
    else
      extra_strict=(-f "ba" -x --audio-format m4a --embed-thumbnail "${meta_args[@]}")
      extra_lenient=(-f "ba/b" -x --audio-format m4a --embed-thumbnail "${meta_args[@]}")
    fi
  elif [ "$QUALITY" = "max" ]; then
    # "max" — הטוב ביותר הזמין; אין מגבלת מינימום, סבב אחד מספיק
    extra_strict=(-f "bv*+ba/b" --merge-output-format mp4 "${meta_args[@]}")
    skip_lenient=1
  else
    # וידאו במספר: סבב א' דורש >= 720p (או >= המבוקש אם נמוך מ-720) —
    # פורמט 18 (360p) לא עובר. סבב ב' מקבל כל דבר <= האיכות המבוקשת.
    local min_h="$QUALITY"
    if echo "$QUALITY" | grep -qE '^[0-9]+$' && [ "$QUALITY" -ge 720 ]; then
      min_h=720
    fi
    extra_strict=(-f "bv*[height<=${QUALITY}][height>=${min_h}][ext=mp4]+ba[ext=m4a]/b[height<=${QUALITY}][height>=${min_h}]" --merge-output-format mp4 "${meta_args[@]}")
    extra_lenient=(-f "bv*[height<=${QUALITY}][ext=mp4]+ba[ext=m4a]/b[height<=${QUALITY}]/b" --merge-output-format mp4 "${meta_args[@]}")
  fi

  # סדר הלקוחות (מחקר ובדיקה מקומית מאומתים 2026-11-01):
  # visionos,web — ברירת המחדל של yt-dlp: visionos לא מושפע מ-SABR, ללא PO Token,
  #   ללא JS player; נבדק מקומית — החזיר 1080p מלא (אף 4K) לסרטון הבדיקה
  # tv — שבור כרגע (#17389 "The page needs to be reloaded") אך עשוי לחזור
  # ios — לפעמים מחזיר אפס פורמטים
  # android — נופל ל-360p תחת SABR אך לא נחסם כמעט לעולם (מפלט ודאי)
  # web_embedded — מפלט אחרון
  # --force-ipv4: מאלץ שימוש ב-IPv4 בלבד, לעקיפת חסימות IP של DC
  local -a clients=("visionos,web" "tv" "ios" "android" "web_embedded")
  local -a proxy_args=()
  [ -n "$PROXY" ] && { proxy_args=(--proxy "$PROXY"); log "yt-dlp עובד דרך פרוקסי: $PROXY"; }

  # הרצה: run_attempts <תווית> <מס' סבבים> <פרמטרי yt-dlp...>
  run_attempts() {
    local label="$1" passes="$2"; shift 2
    local pass client first=1
    for ((pass=1; pass<=passes; pass++)); do
      for client in "${clients[@]}"; do
        log "מנסה yt-dlp [$label] client: $client (סבב $pass)"
        # המתנה רק בין נסיונות (YouTube מאטל DC IPs); הנסיון הראשון מתחיל מיד
        if [ "$first" -eq 0 ]; then
          sleep 20
        fi
        first=0
        if yt-dlp \
            --js-runtimes node \
            --remote-components ejs:github \
            --extractor-args "youtube:player_client=$client" \
            --sleep-requests 2 \
            --retries 5 \
            --force-ipv4 \
            "${proxy_args[@]}" \
            "$@" \
            -o "$out_pattern" \
            --no-playlist \
            "$URL" >"$OUTPUT_DIR/ytdlp-verbose.log" 2>&1; then
          log "✔ client $client הצליח [$label]"
          tail -3 "$OUTPUT_DIR/ytdlp-verbose.log" | tee -a "$LOG_FILE"
          return 0
        fi
        log "  ✖ $client: $(grep -m1 -iE '^(ERROR|yt-dlp: error)' "$OUTPUT_DIR/ytdlp-verbose.log" 2>/dev/null | cut -c1-140)"
      done
    done
    return 1
  }

  # --- סבב א': איכות מלאה (לא מתפשר על רזולוציה/אודיו נפרד) ---
  if run_attempts "איכות מלאה" 1 "${extra_strict[@]}"; then
    return 0
  fi

  # --- סבב ב': התאמה (הטוב ביותר הזמין, כדי לא לחסום סרטים ישנים) ---
  if [ "$skip_lenient" -eq 0 ]; then
    log "סבב איכות מלאה לא צלח — עובר לסבב התאמה (האיכות הזמינה)"
    if run_attempts "התאמה" 2 "${extra_lenient[@]}"; then
      return 0
    fi
  fi

  log "yt-dlp נכשל בכל נסיונות הלקוחות (visionos,web,tv,ios,android,web_embedded)"
  return 1
}

# -----------------------------------------------------------------------------
# ריצה
# -----------------------------------------------------------------------------
log "מתחיל: $URL | מצב=$MODE | איכות=$QUALITY"

# וידוא ש-ffmpeg זמין (המרת אודיו, מיזוג וידאו+אודיו)
ensure_ffmpeg

# ניסיון ראשון: yt-dlp עם לקוחות visionos,web (ברירת המחדל, עוקפים SABR)
try_android_web || try_cobalt || fail "כל השכבות נכשלו"

verify_output
