#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# embed-cover.py — החלפת תמונת הקאבר המוטמעת בקובץ אודיו (mp3 / m4a)
# שימוש: embed-cover.py <קובץ-אודיו> <תמונה-חתוכה>
#
# כותב דרך mutagen — התגיות התקניות: APIC ל-mp3, covr ל-m4a — בלי לגעת
# באודיו עצמו (ניסוי מקומי 2026-11-02: mp3+m4a החזירו קאבר 720x720,
# bitrate והתגיות האחרות לא נגעו). מפתחות MP4Tags הם מחרוזות (str),
# לא bytes — אומת בקוד המקור של mutagen 1.48.
# כל שגיאה יוצאת עם קוד יציאה != 0 והקריאה (square_cover) משאירה
# את הקאבר המקורי במקום — לא קטלני.
# -----------------------------------------------------------------------------
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("שימוש: embed-cover.py <קובץ-אודיו> <תמונה>", file=sys.stderr)
        return 2
    audio, img = sys.argv[1], sys.argv[2]
    data = Path(img).read_bytes()
    # mime לפי חתימת הקובץ — לא לפי הסיומת
    mime = "image/png" if data[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"

    if audio.lower().endswith(".mp3"):
        from mutagen.id3 import APIC, ID3
        tags = ID3(audio)
        tags.delall("APIC")  # מסירים את התמונה הישנה قبل הוספת החדשה
        tags.add(APIC(encoding=3, mime=mime, type=3, desc="Cover", data=data))
        tags.save(v2_version=4)  # id3v2.4 — עקביות עם yt-dlp; TDRC (תאריך
        #   מלא) נשמר גם ב-3 (אומת), אך 4 הוא התקן הרשמי ותואם ל-mp3 הטרי
    else:
        from mutagen.mp4 import MP4, MP4Cover
        mp4 = MP4(audio)
        if mp4.tags is None:
            mp4.add_tags()
        fmt = MP4Cover.FORMAT_PNG if mime == "image/png" else MP4Cover.FORMAT_JPEG
        mp4.tags["covr"] = [MP4Cover(data, imageformat=fmt)]
        mp4.save()

    print(f"OK {mime} {len(data)} bytes -> {audio}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 — כל כשלון = יציאה לא קטלנית
        print(f"embed-cover.py נכשל: {err}", file=sys.stderr)
        sys.exit(1)
