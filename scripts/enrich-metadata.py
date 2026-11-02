#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# enrich-metadata.py — העשרת תגיות אודיו ממאגר iTunes החינמי (שלב 2)
# שימוש: enrich-metadata.py <קובץ-אודيو (mp3 / m4a)>
#
# הרעיון: yt-dlp (שלב 1) כותב מה שיוטיוב יודע. לסרטון רגיל חסרים אלבום,
# תאריך שחרור, ז'אנר אמיתי ומספר רצועה — את אלה נותנת iTunes Search API
# ללא מפתח (אומת בניסוי 2026-11-02: ~0.5s לתשובה; לסרטון לא-מוזיקלי
# הגיעו 0 תוצאות — מה שמבטיח שלא כותבים שטויות על סרטון רגיל).
#
# הגנת התאמה: משך הקובץ חייב להתאים לאורך השיר במאגר (סף 10 שניות).
# iTunes מחזיר גם גרסאות חיות/דומות באורכים אחרות — אלה נדחות, וכשאין
# התאמה — לא כותבים דבר. זה מה שמונע לשייך שיר לאלבום לא נכון.
#
# לא קטלני: כשלון רשת או חריגה יוצא בקוד 1 ונסקרב ע"י ה-wrapper
# enrich_metadata ב-download-lib.sh — ההורדה לא נופלת. "לא נמצא/לא תואם"
# יוצא בקוד 0 — מצב תקין, לא שגיאה.
#
# ללא תלויות חדשות: urllib (רשת) + mutagen (תגיות) + ffprobe (משך).
# -----------------------------------------------------------------------------
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

# פלט UTF-8 קבוע: כשהפלט מנותב ל-LOG_FILE הקידוד הוא locale (cp1255 בוינדוז)
# שלא יודע לתאר סימן ✓ — כל הרצה מוצלחת הייתה מסתיימת ביציאה 1 בשגיאה.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001 — Python ישן מדי = משאירים ברירת מחדל
        pass

ITUNES_URL = "https://itunes.apple.com/search"
TOLERANCE_SEC = 10      # סף התאמת משך בין הקובץ למאגר (שניות)
TERM_MAX = 200          # הגבלת אורך מונח החיפוש (מניעת URL ארוך מדי)
UA = "ConstructionApp/1.0 (metadata enrichment)"

# מיפוי שדות הכתיבה לאטומי MP4 (אותיות רגילות; © הוא U+00A9)
MP4_KEYS = {"album": "©alb", "date": "©day", "genre": "©gen",
            "artist": "©ART", "title": "©nam"}


def probe_duration(path):
    """משך הקובץ בשניות דרך ffprobe; None אם לא ניתן למדוד."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        return float(out.stdout.strip())
    except Exception:  # noqa: BLE001 — ffprobe חסר/כישלון = לא נדע להתאים
        return None


def _text(value):
    """קריאת ערך תגית כמחרוזת (mutagen מחזיר גם bytes בגרסאות ישנות)."""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value) if value is not None else ""


def read_tags(path):
    """(כותרת, אמן) מהתגיות הקיימות; ריק אם אין תגיות או שהפורמט לא נתמך."""
    try:
        if path.suffix.lower() == ".mp3":
            from mutagen.id3 import ID3
            tags = ID3(str(path))
            title = _text(tags.get("TIT2").text[0]) if tags.get("TIT2") else ""
            artist = _text(tags.get("TPE1").text[0]) if tags.get("TPE1") else ""
            return title, artist
        if path.suffix.lower() == ".m4a":
            from mutagen.mp4 import MP4
            tags = MP4(str(path)).tags or {}
            title = _text((tags.get(MP4_KEYS["title"]) or [""])[0])
            artist = _text((tags.get(MP4_KEYS["artist"]) or [""])[0])
            return title, artist
    except Exception:  # noqa: BLE001 — אין תגיות בכלל = נ fallback לשם הקובץ
        pass
    return "", ""


def sniff_content(path):
    """פורמט אמיתי לפי תוכן הקובץ — הסיומת עלשה עלולה לשקר (cobalt).

    מחזיר 'mp3', 'm4a', או ריק אם לא זוהה. נחוץ לפני כתיבה: החדרת תגית
    ID3 לתוך מיכל שאינו mp3 תקלקל את הקובץ.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(12)
    except OSError:
        return ""
    if head[:3] == b"ID3" or (len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0):
        return "mp3"
    if len(head) >= 8 and head[4:8] == b"ftyp":
        return "m4a"
    return ""


def title_from_filename(path):
    """כותרת מתוך שם הקובץ: 'שם שיר [מזהה-יוטיוב-11-תווים].mp3' → 'שם שיר'."""
    name = path.stem.strip()
    m = re.match(r"^(.*) \[[A-Za-z0-9_-]{11}\]$", name)
    return (m.group(1) if m else name).strip()


def search_itunes(term):
    """חיפוש שיר ב-iTunes (ללא מפתח); זורק חריגת רשת — נתפס למעלה."""
    url = ITUNES_URL + "?" + urllib.parse.urlencode(
        {"term": term, "media": "music", "entity": "song", "limit": 5})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("results") or []


def pick_match(results, duration):
    """הרשומה הראשונה שמשך השיר בה תואם למשך הקובץ (±TOLERANCE_SEC), או None."""
    for rec in results:
        ms = rec.get("trackTimeMillis")
        if ms and abs(ms / 1000.0 - duration) <= TOLERANCE_SEC:
            return rec
    return None


def build_fields(rec):
    """שדות הכתיבה מרשומת iTunes; ערכים ריקים = לא כותבים את השדה."""
    iso = (rec.get("releaseDate") or "")[:10]
    return {
        "album": rec.get("collectionName") or "",
        "date": iso.replace("-", "") if len(iso) == 10 else "",
        "genre": rec.get("primaryGenreName") or "",
        "artist": rec.get("artistName") or "",
        "track": rec.get("trackNumber") or 0,
        "tracks": rec.get("trackCount") or 0,
    }


def _set_id3(tags, frame_id, frame_cls, value):
    """החלפת תגית mp3 ייחודית (לא הוספה מצטברת) — העיקרון של embed-cover.py."""
    if value:
        tags.delall(frame_id)
        tags.add(frame_cls(encoding=3, text=[value]))


def write_tags(path, fields):
    """כתיבת השדות לתגיות הקובץ — mp3 דרך ID3, m4a דרך אטומי MP4."""
    if path.suffix.lower() == ".mp3":
        from mutagen.id3 import ID3, TALB, TDRC, TCON, TPE1, TRCK
        try:
            tags = ID3(str(path))
        except Exception:  # noqa: BLE001 — אין תגיות כלל (למשל הורדת cobalt)
            tags = ID3()   # ניצור תגית חדשה בכתיבה (mutagen יודעת להכניסה)
        _set_id3(tags, "TALB", TALB, fields["album"])
        _set_id3(tags, "TDRC", TDRC, fields["date"])
        _set_id3(tags, "TCON", TCON, fields["genre"])
        _set_id3(tags, "TPE1", TPE1, fields["artist"])
        if fields["track"]:
            trk = f'{fields["track"]}/{fields["tracks"]}' if fields["tracks"] else str(fields["track"])
            _set_id3(tags, "TRCK", TRCK, trk)
        # נתיב מועבר במפורש — נדרש כשאין תגית קיימת (ID3 ריק נבנה ללא קובץ)
        tags.save(str(path), v2_version=4)  # עקביות עם yt-dlp ו-embed-cover.py
    else:
        from mutagen.mp4 import MP4
        mp4 = MP4(str(path))
        if mp4.tags is None:
            mp4.add_tags()
        for field in ("album", "date", "genre", "artist"):
            if fields[field]:
                mp4.tags[MP4_KEYS[field]] = [fields[field]]
        if fields["track"]:
            mp4.tags["trkn"] = [(fields["track"], fields["tracks"] or 0)]
        mp4.save()


def main() -> int:
    if len(sys.argv) != 2:
        print("שימוש: enrich-metadata.py <קובץ-אודיו>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"enrich-metadata.py: הקובץ לא נמצא: {path}", file=sys.stderr)
        return 2
    kind = sniff_content(path)
    if not kind:
        print("ENRICH — דולג: סוג הקובץ לא זוהה לפי התוכן")
        return 0
    if path.suffix.lower().lstrip(".") != kind:
        print(f"ENRICH — דולג: הסיומת {path.suffix} אך התוכן הוא {kind} — לא כותבים")
        return 0

    title, artist = read_tags(path)
    if not title:
        title = title_from_filename(path)  # נפילה לשם הקובץ כשאין תגיות
    if not title:
        print("ENRICH — דולג: אין כותרת לחיפוש")
        return 0

    duration = probe_duration(path)
    if duration is None:
        print("ENRICH — דולג: לא ניתן למדוד משך (ffprobe חסר?)")
        return 0

    term = (f"{title} {artist}" if artist else title)[:TERM_MAX]
    results = search_itunes(term)
    rec = pick_match(results, duration)
    if rec is None:
        print(f"ENRICH — אין התאמה ({len(results)} תוצאות, משך הקובץ {duration:.0f}s)")
        return 0

    fields = build_fields(rec)
    if not any(fields.values()):
        print("ENRICH — אין התאמה: הרשומה החוזרת ריקה")
        return 0
    write_tags(path, fields)
    summary = ", ".join(f"{k}={v}" for k, v in fields.items() if v)
    print(f"ENRICH ✓ {summary}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 — כשלון לא צפוי = יציאה 1 (לא קטלני)
        print(f"enrich-metadata.py נכשל: {err}", file=sys.stderr)
        sys.exit(1)
