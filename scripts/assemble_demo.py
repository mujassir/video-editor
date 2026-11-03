#!/usr/bin/env python3
"""Builds the narrated demo video from a simulator screen recording.

Inputs:
  --recording   simulator screen recording (mp4)
  --record-start epoch seconds when recording started
  --log         UI test log containing "CHAPTER <n> <epoch>" lines
  --script      scripts/narration.json
  --narration   folder with chapter-NN.aiff narration clips
  --out         output mp4

Each chapter becomes a 1920x1080 segment: a title panel on the left and the
phone recording on the right, with the chapter's narration. Waiting time that
outlasts the narration (exports, analysis) is cut down to a short jump so the
video keeps moving.
"""
import argparse, json, os, re, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
PHONE_H = 1000
ACCENT = (255, 60, 97)


def run(cmd):
    print("+", " ".join(cmd[:6]), "…" if len(cmd) > 6 else "", flush=True)
    subprocess.run(cmd, check=True)


def probe_duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)


def probe_size(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                          "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout.strip()
    w, h = out.split(",")[:2]
    return int(w), int(h)


def font(size, bold=True):
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
    ]
    for c in candidates:
        if os.path.exists(c):
            try:
                f = ImageFont.truetype(c, size)
                if c.endswith("SFNS.ttf"):
                    try:
                        f.set_variation_by_name("Bold" if bold else "Regular")
                    except Exception:
                        pass
                return f
            except Exception:
                continue
    return ImageFont.load_default()


def background(path, title, subtitle, index, total, phone_box, full_title=False):
    img = Image.new("RGB", (W, H), (14, 14, 18))
    d = ImageDraw.Draw(img)
    # Soft accent glows.
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-300, -350, 900, 650), fill=(120, 30, 70))
    gd.ellipse((1100, 500, 2300, 1500), fill=(55, 30, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    img = Image.blend(img, glow, 0.55)
    d = ImageDraw.Draw(img)

    x0 = 130
    if full_title:
        d.text((x0, 380), title, font=font(118), fill=(255, 255, 255))
        d.text((x0, 520), subtitle, font=font(46, bold=False), fill=(220, 220, 230))
        d.rounded_rectangle((x0, 610, x0 + 120, 618), radius=4, fill=ACCENT)
        d.text((x0, 660), "Native iPhone app · Swift · Metal · on-device AI", font=font(30, bold=False), fill=(170, 170, 185))
    else:
        d.text((x0, 150), f"{index:02d} / {total - 2:02d}", font=font(30), fill=ACCENT)
        y = 210
        for line in wrap(title, font(84), 760):
            d.text((x0, y), line, font=font(84), fill=(255, 255, 255))
            y += 98
        d.rounded_rectangle((x0, y + 18, x0 + 96, y + 25), radius=4, fill=ACCENT)
        y += 60
        for line in wrap(subtitle, font(38, bold=False), 760):
            d.text((x0, y), line, font=font(38, bold=False), fill=(200, 200, 212))
            y += 50
    d.text((x0, H - 90), "Cutline · iPhone · v1 demo", font=font(24, bold=False), fill=(130, 130, 145))

    # Phone shadow + bezel behind the recording.
    px, py, pw, ph = phone_box
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((px - 18, py - 18 + 20, px + pw + 18, py + ph + 18 + 20), radius=70, fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    img = Image.alpha_composite(img.convert("RGBA"), shadow)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((px - 14, py - 14, px + pw + 14, py + ph + 14), radius=66, fill=(28, 28, 32), outline=(70, 70, 78), width=3)
    img.convert("RGB").save(path)


def wrap(text, f, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if f.getlength(trial) <= max_w:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def phone_mask(path, w, h, radius):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)
    m.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recording", required=True)
    ap.add_argument("--record-start", type=float, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--script", required=True)
    ap.add_argument("--narration", required=True)
    ap.add_argument("--work", default="demo-work")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-tail", type=float, default=2.5, help="seconds kept from the end of an over-long chapter")
    a = ap.parse_args()

    script = json.load(open(a.script))
    chapters = script["chapters"]
    marks = {}
    for line in open(a.log, errors="ignore"):
        m = re.search(r"CHAPTER (\d+) ([\d.]+)", line)
        if m:
            marks[int(m.group(1))] = float(m.group(2)) - a.record_start
    if not marks:
        sys.exit("no CHAPTER marks in log")
    rec_len = probe_duration(a.recording)
    rw, rh = probe_size(a.recording)
    pw = int(round(PHONE_H * rw / rh / 2)) * 2
    phone_box = (W - 160 - pw, (H - PHONE_H) // 2, pw, PHONE_H)
    os.makedirs(a.work, exist_ok=True)
    mask = os.path.join(a.work, "mask.png")
    phone_mask(mask, pw, PHONE_H, 54)

    segments = []
    order = sorted(marks)
    for k, idx in enumerate(order):
        start = max(0.0, marks[idx])
        end = marks[order[k + 1]] if k + 1 < len(order) else rec_len
        end = min(end, rec_len)
        narr = os.path.join(a.narration, f"chapter-{idx:02d}.aiff")
        narr_len = probe_duration(narr) if os.path.exists(narr) else 3.0
        keep_head = narr_len + 0.8
        length = end - start
        # Spans of the recording to keep for this chapter.
        if length > keep_head + a.max_tail + 1.0:
            spans = [(start, start + keep_head), (end - a.max_tail, end)]
        else:
            spans = [(start, max(end, start + 0.5))]
        ch = chapters[idx] if idx < len(chapters) else {"title": "", "subtitle": ""}
        bg = os.path.join(a.work, f"bg-{idx:02d}.png")
        background(bg, ch["title"], ch.get("subtitle", ""), idx, len(chapters), phone_box,
                   full_title=(idx == 0 or idx == len(chapters) - 1))
        seg = os.path.join(a.work, f"seg-{idx:02d}.mp4")
        # Build trimmed phone video from spans.
        filters, labels = [], []
        for i, (s, e) in enumerate(spans):
            filters.append(f"[0:v]trim=start={s:.3f}:end={e:.3f},setpts=PTS-STARTPTS,fps=30,scale={pw}:{PHONE_H}[p{i}]")
            labels.append(f"[p{i}]")
        if len(labels) > 1:
            filters.append("".join(labels) + f"concat=n={len(labels)}:v=1:a=0[phone]")
        else:
            filters.append(f"{labels[0]}null[phone]")
        filters.append("[phone][2:v]alphamerge[rounded]")
        filters.append(f"[1:v][rounded]overlay={phone_box[0]}:{phone_box[1]}:shortest=1,format=yuv420p[v]")
        seg_len = sum(e - s for s, e in spans)
        filters.append(f"[3:a]aresample=48000,apad,atrim=0:{seg_len:.3f},aformat=channel_layouts=stereo[a]")
        run(["ffmpeg", "-loglevel", "error", "-y",
             "-i", a.recording, "-loop", "1", "-i", bg, "-loop", "1", "-i", mask, "-i", narr,
             "-filter_complex", ";".join(filters), "-map", "[v]", "-map", "[a]",
             "-t", f"{seg_len:.3f}", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-r", "30",
             "-c:a", "aac", "-b:a", "160k", seg])
        segments.append(seg)
        print(f"chapter {idx}: {length:.1f}s recorded → {seg_len:.1f}s kept (narration {narr_len:.1f}s)")

    listing = os.path.join(a.work, "segments.txt")
    with open(listing, "w") as f:
        for s in segments:
            f.write(f"file '{os.path.abspath(s)}'\n")
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
         "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "160k",
         "-movflags", "+faststart", a.out])
    print(f"DEMO duration: {probe_duration(a.out):.1f}s")


if __name__ == "__main__":
    main()
