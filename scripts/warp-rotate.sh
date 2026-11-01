#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# warp-rotate.sh — סיבוב כתובת יציאה של Cloudflare WARP
# חסימת "Sign in to confirm you're not a bot" היא per-IP: חלק מכתובות היציאה
# של WARP מסומנות אצל יוטיוב. רישום חשבון WARP חדש (wgcf) מייצר כתובת חדשה.
#
# שימוש: warp-rotate.sh [warp_dir]   (ברירת מחדל: warp)
# -----------------------------------------------------------------------------
set -u -o pipefail
WARP_DIR="${1:-warp}"

cd "$WARP_DIR" || { echo "✖ תיקיית WARP לא נמצאה: $WARP_DIR"; exit 1; }
[ -x ./wgcf ] && [ -x ./wireproxy ] || { echo "✖ wgcf/wireproxy לא נמצאו ב-$WARP_DIR"; exit 1; }

# כתובת היציאה הנוכחית דרך ה-proxy (לבדיקה שהכתובת אכן השתנתה)
get_ip() {
  curl -fsS --max-time 15 -x http://127.0.0.1:1080 \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2
}
old_ip=$(get_ip || true)
echo "כתובת היציאה הנוכחית: ${old_ip:-לא ידועה}"

# 1. השבתת wireproxy הפעיל
pkill -f 'wireproxy -c' 2>/dev/null || true
sleep 2

# 2. חשבון WARP חדש — מחיקת החשבון הישן מכריחה wgcf ליצור חדש (כתובת יציאה חדשה)
rm -f wgcf-account.toml wgcf-profile.conf
./wgcf register --accept-tos >/dev/null 2>&1 \
  || { echo "✖ רישום חשבון WARP חדש נכשל"; exit 1; }
./wgcf generate >/dev/null 2>&1 \
  || { echo "✖ יצירת פרופיל WireGuard נכשלה"; exit 1; }

# 3. שכבת proxy HTTP — wgcf מייצר את הקובץ מחדש, יש להוסיף בכל פעם
printf '\n[http]\nBindAddress = 127.0.0.1:1080\n' >> wgcf-profile.conf

# 4. הפעלה מחדש + המתנה לעליית ה-proxy (עד 60 שניות)
nohup ./wireproxy -c wgcf-profile.conf > wireproxy.log 2>&1 &
echo $! > wireproxy.pid
new_ip=""
for i in $(seq 1 30); do
  sleep 2
  if new_ip=$(get_ip) && [ -n "$new_ip" ]; then
    echo "ה-proxy עלה אחרי $((i * 2)) שניות"
    break
  fi
done
if [ -z "$new_ip" ]; then
  echo "✖ ה-proxy לא עלה אחרי הסיבוב — הלוג:"
  tail -20 wireproxy.log
  exit 1
fi

echo "כתובת היציאה החדשה: $new_ip"
if [ -n "$old_ip" ] && [ "$new_ip" = "$old_ip" ]; then
  echo "::warning::הכתובת לא השתנתה אחרי הרישום מחדש"
else
  echo "✔ סיבוב IP הצליח — הכתובת השתנתה"
fi
