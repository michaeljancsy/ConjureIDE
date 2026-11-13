#!/usr/bin/env python3
"""Cut a raw demo take into a fixed-length 1920x1080 video from a JSON cut list.

    python3 edit_demo.py cutlist.json

Cut list shape (times in seconds of the raw take; crop in raw pixels):

{
  "raw": "~/Music/ConjureDSP-Demo/captures/raw-take1.mov",
  "out": "~/.../demo-60s-2026-11-12.mp4",
  "workdir": "/tmp/edit",
  "fps": 30,
  "segments": [
    {"start": 3.0, "end": 8.0,               # raw range
     "speed": 1,                              # >1 = sped up (video only)
     "crop": [x, y, w, h],                    # 16:9 region of the raw frame
     "overlays": [{"png": "c1.png", "from": 0, "to": 5}],  # seconds of OUTPUT segment time
     "audio": [[3.0, 8.0]]},                  # raw ranges whose audio plays under it
    {"image": "endcard.png", "duration": 4}   # still card
  ],
  "audio_fade_out": 1.5
}

Video of each segment is cut, cropped, scaled to 1920x1080, sped up and has its
overlay PNGs laid on top (each overlay fades in/out over 0.25 s). Audio is
assembled separately from the listed raw ranges (real-time, never sped up,
crossfaded) so the sound stays natural while the picture is sped up; it is cut
or padded to the segment's output length.
"""
import json
import os
import subprocess
import sys


def run(cmd):
    print("+", " ".join(str(c) for c in cmd)[:400], flush=True)
    subprocess.run([str(c) for c in cmd], check=True)


def expand(p):
    return os.path.expanduser(p)


def seg_duration(seg):
    if "image" in seg:
        return float(seg["duration"])
    return (seg["end"] - seg["start"]) / float(seg.get("speed", 1))


def render_video(seg, raw, out, fps):
    dur = seg_duration(seg)
    if "image" in seg:
        run(["ffmpeg", "-y", "-loop", "1", "-framerate", fps, "-t", f"{dur:.3f}",
             "-i", expand(seg["image"]),
             "-vf", "scale=1920:1080,format=yuv420p,fade=t=in:st=0:d=0.4",
             "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-r", fps, "-an", out])
        return
    x, y, w, h = seg["crop"]
    speed = float(seg.get("speed", 1))
    inputs = ["-ss", f"{seg['start']:.3f}", "-to", f"{seg['end']:.3f}", "-i", raw]
    chain = (f"[0:v]crop={w}:{h}:{x}:{y},scale=1920:1080:flags=lanczos,"
             f"setpts=(PTS-STARTPTS)/{speed},fps={fps},format=yuva420p[v0]")
    last = "v0"
    for i, ov in enumerate(seg.get("overlays", [])):
        inputs += ["-loop", "1", "-i", expand(ov["png"])]
        a, b = ov.get("from", 0), min(ov.get("to", dur), dur)
        fade = 0.25
        chain += (f";[{i + 1}:v]format=rgba,fade=t=in:st={a}:d={fade}:alpha=1,"
                  f"fade=t=out:st={max(a, b - fade)}:d={fade}:alpha=1[o{i}]"
                  f";[{last}][o{i}]overlay=0:0:shortest=0:enable='between(t,{a},{b})'[v{i + 1}]")
        last = f"v{i + 1}"
    chain += f";[{last}]format=yuv420p[vout]"
    run(["ffmpeg", "-y", *inputs, "-filter_complex", chain, "-map", "[vout]",
         "-t", f"{dur:.3f}", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
         "-r", fps, "-an", out])


def render_audio(seg, raw, out):
    dur = seg_duration(seg)
    ranges = seg.get("audio") or []
    if not ranges:
        run(["ffmpeg", "-y", "-f", "lavfi", "-t", f"{dur:.3f}", "-i",
             "anullsrc=r=48000:cl=stereo", "-c:a", "pcm_s16le", out])
        return
    inputs, labels = [], []
    for i, (a, b) in enumerate(ranges):
        inputs += ["-ss", f"{a:.3f}", "-to", f"{b:.3f}", "-i", raw]
        labels.append(f"[{i}:a]")
    if len(ranges) == 1:
        chain = f"{labels[0]}aresample=48000,apad,atrim=0:{dur:.3f}[aout]"
    else:
        chain, last = "", labels[0]
        for i in range(1, len(ranges)):
            chain += f"{last}{labels[i]}acrossfade=d=0.6:c1=tri:c2=tri[x{i}];"
            last = f"[x{i}]"
        chain += f"{last}aresample=48000,apad,atrim=0:{dur:.3f}[aout]"
    run(["ffmpeg", "-y", *inputs, "-filter_complex", chain, "-map", "[aout]",
         "-ac", "2", "-c:a", "pcm_s16le", out])


def main():
    cl = json.load(open(sys.argv[1]))
    raw = expand(cl["raw"])
    out = expand(cl["out"])
    wd = expand(cl.get("workdir", "/tmp/demo-edit"))
    fps = str(cl.get("fps", 30))
    os.makedirs(wd, exist_ok=True)
    vlist, alist = [], []
    total = 0.0
    for i, seg in enumerate(cl["segments"]):
        v = os.path.join(wd, f"seg{i:02d}.mp4")
        a = os.path.join(wd, f"seg{i:02d}.wav")
        render_video(seg, raw, v, fps)
        render_audio(seg, raw, a)
        vlist.append(v)
        alist.append(a)
        total += seg_duration(seg)
    print(f"planned total {total:.3f}s")
    with open(os.path.join(wd, "v.txt"), "w") as f:
        f.writelines(f"file '{p}'\n" for p in vlist)
    with open(os.path.join(wd, "a.txt"), "w") as f:
        f.writelines(f"file '{p}'\n" for p in alist)
    vcat = os.path.join(wd, "video.mp4")
    acat = os.path.join(wd, "audio.wav")
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", os.path.join(wd, "v.txt"), "-c", "copy", vcat])
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", os.path.join(wd, "a.txt"), "-c", "copy", acat])
    fo = float(cl.get("audio_fade_out", 1.5))
    run(["ffmpeg", "-y", "-i", vcat, "-i", acat,
         "-af", f"afade=t=out:st={total - fo:.3f}:d={fo},atrim=0:{total:.3f}",
         "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
         "-t", f"{total:.3f}", "-movflags", "+faststart", out])
    print("wrote", out)


if __name__ == "__main__":
    main()
