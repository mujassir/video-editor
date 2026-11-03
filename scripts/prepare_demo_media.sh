#!/bin/bash
# Cuts demo clips from "Tears of Steel" (c) Blender Foundation, CC BY 3.0 – mango.blender.org
# and adds a voice track to the close-up so captions / silence removal have speech to work with.
set -euo pipefail
OUT=${1:?output folder}
WORK=${2:-/tmp/demo-prep}
mkdir -p "$OUT" "$WORK"
SRC="$WORK/tos.mov"
[ -f "$SRC" ] || curl -fsSL --retry 3 -o "$SRC" https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov

# Shot boundaries (scene changes) so each clip stays inside one shot.
ffmpeg -hide_banner -i "$SRC" -vf "select='gt(scene,0.28)',showinfo" -an -f null - 2>&1 \
  | grep -oE "pts_time:[0-9.]+" | cut -d: -f2 > "$WORK/cuts.txt" || true
echo "found $(wc -l < "$WORK/cuts.txt") shot boundaries"

# shot_around T MAXLEN -> "start duration" of the shot containing T, clamped to MAXLEN around T.
shot_around() {
  python3 - "$WORK/cuts.txt" "$1" "$2" <<'PY'
import sys
cuts=[0.0]+[float(x) for x in open(sys.argv[1]) if x.strip()]+[734.0]
t=float(sys.argv[2]); maxlen=float(sys.argv[3])
a=max(c for c in cuts if c<=t); b=min(c for c in cuts if c>t)
a+=0.15; b-=0.15
if b-a>maxlen:
    a=max(a,t-maxlen/2); b=a+maxlen
print(f"{a:.2f} {b-a:.2f}")
PY
}

cut() { # name time maxlen
  read -r s d < <(shot_around "$2" "$3")
  echo "$1: start $s length $d"
  ffmpeg -loglevel error -y -ss "$s" -t "$d" -i "$SRC" -vf "scale=1280:-2" -c:v libx264 -preset fast -crf 18 \
    -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 "$OUT/$1.mov"
}

cut 01-bridge 31 6
cut 03-skyline 21 5
cut 04-plaza 262 5
cut 05-canal 231 5

# 02 – the "vlog": close-up shot, slowed / looped to fit a spoken line with pauses.
say -v "Reed (English (US))" -r 170 -o "$WORK/vlog.aiff" \
  "Hey everyone, welcome back. [[slnc 1400]] Today I'm editing this whole video on my iPhone. [[slnc 1500]] And everything runs on device."
VLEN=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/vlog.aiff")
best_s=0; best_d=0
for t in 322 352 383 335 345 360 372; do
  read -r cs cd < <(shot_around $t 12)
  if python3 -c "import sys; sys.exit(0 if $cd > $best_d else 1)"; then best_s=$cs; best_d=$cd; fi
done
s=$best_s; d=$best_d
echo "vlog shot: start $s length $d, speech $VLEN"
ffmpeg -loglevel error -y -ss "$s" -t "$d" -i "$SRC" -an -vf "scale=1280:-2" -c:v libx264 -crf 18 "$WORK/vlog-shot.mov"
# Ping-pong loop the shot until it covers the speech.
ffmpeg -loglevel error -y -i "$WORK/vlog-shot.mov" -filter_complex "[0:v]split[a][b];[b]reverse[r];[a][r]concat=n=2:v=1[pp]" \
  -map "[pp]" -c:v libx264 -crf 18 "$WORK/vlog-pp.mov"
ffmpeg -loglevel error -y -stream_loop 6 -i "$WORK/vlog-pp.mov" -i "$WORK/vlog.aiff" -map 0:v -map 1:a \
  -t "$VLEN" -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 "$OUT/02-vlog.mov"
ls -la "$OUT"
