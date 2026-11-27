#!/usr/bin/env python3
"""Reference build = the MJ V2 build() pipeline, unmodified logic, with configurable paths.
Usage: reference_build.py video template output   (needs ffmpeg/ffprobe + the template)"""
import sys, os, re, json, glob, zipfile, shutil, subprocess, tempfile

def run(cmd): return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, text=True)

def build(video, base_path, output):
    work = tempfile.mkdtemp(prefix="wallpaper-")
    try:
        meta = json.loads(run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height,avg_frame_rate",
                               "-show_entries","format=duration","-of","json",video]).stdout)
        duration = float(meta["format"]["duration"])
        fd = os.path.join(work, "frames"); os.makedirs(fd)
        run(["ffmpeg","-y","-v","error","-i",video,"-map","0:v:0","-vf","scale=468:1013:force_original_aspect_ratio=increase,crop=468:1013",
             "-fps_mode","passthrough","-q:v","2",os.path.join(fd,"frame-%06d.jpg")])
        frames = sorted(glob.glob(fd + "/*.jpg"))
        base = zipfile.ZipFile(base_path)
        bp = next(n for n in base.namelist() if "Background" in n and n.endswith("main.caml"))
        ad = bp.rsplit("/",1)[0] + "/assets/"
        caml = base.read(bp).decode()
        vals = "\n".join('                  <CGImage src="assets/%d.jpg"/>' % i for i in range(len(frames)))
        caml = re.sub(r"<values>.*?</values>", lambda m: "<values>\n"+vals+"\n            </values>", caml, count=1, flags=re.S)
        caml = re.sub(r'(<animation\b[^>]*\bduration=")[^"]+(")', lambda m: m.group(1)+str(duration)+m.group(2), caml, count=1)
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as out:
            for info in base.infolist():
                if info.filename.startswith(ad) and info.filename.lower().endswith(".jpg"): continue
                out.writestr(info, caml.encode() if info.filename == bp else base.read(info.filename))
            for i, f in enumerate(frames):
                zi = zipfile.ZipInfo(ad + str(i) + ".jpg"); zi.compress_type = zipfile.ZIP_STORED
                out.writestr(zi, open(f,"rb").read())
        print("frames", len(frames), "duration", duration)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__": build(*sys.argv[1:4])
