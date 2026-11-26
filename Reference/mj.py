#!/usr/bin/env python3
import os, sys, re, json, glob, zipfile, shutil, subprocess, tempfile
from PIL import Image, ImageOps

BASE = "/mnt/files/Video-B-anim.tendies"
REPORT = "/mnt/files/Universal-Video-Wallpaper-Report.txt"
SIZE = (468, 1013)

def run(cmd):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)

def build(video, output):
    work = tempfile.mkdtemp(prefix="wallpaper-", dir="/mnt/files")
    try:
        meta = json.loads(run([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate",
            "-show_entries", "format=duration",
            "-of", "json", video
        ]).stdout)

        duration = float(meta["format"]["duration"])
        stream = meta["streams"][0]
        width, height = stream["width"], stream["height"]

        extracted = os.path.join(work, "frames")
        resized = os.path.join(work, "resized")
        os.makedirs(extracted)
        os.makedirs(resized)

        run([
            "ffmpeg", "-v", "error", "-i", video,
            "-map", "0:v:0", "-vsync", "0",
            os.path.join(extracted, "frame-%06d.jpg")
        ])

        frames = sorted(glob.glob(extracted + "/*.jpg"))
        if not frames:
            raise Exception("No video frames extracted")

        for i, path in enumerate(frames):
            with Image.open(path) as im:
                im = ImageOps.fit(im.convert("RGB"), SIZE,
                                  method=Image.LANCZOS)
                im.save(os.path.join(resized, str(i) + ".jpg"),
                        "JPEG", quality=90)

        with zipfile.ZipFile(BASE) as base:
            bp = next(n for n in base.namelist()
                      if "Background" in n and n.endswith("main.caml"))
            asset_dir = bp.rsplit("/", 1)[0] + "/assets/"
            caml = base.read(bp).decode("utf-8")

            values = "\n".join(
                '                  <CGImage src="assets/%d.jpg"/>' % i
                for i in range(len(frames))
            )

            caml, count = re.subn(
                r"<values>.*?</values>",
                "<values>\n" + values + "\n            </values>",
                caml, count=1, flags=re.S
            )
            if count != 1:
                raise Exception("Animation values block not found")

            caml, count = re.subn(
                r'(<animation\b[^>]*\bduration=")[^"]+(")',
                lambda m: m.group(1) + str(duration) + m.group(2),
                caml, count=1
            )
            if count != 1:
                raise Exception("Animation duration not found")

            with zipfile.ZipFile(output, "w",
                                 zipfile.ZIP_DEFLATED) as out:
                for info in base.infolist():
                    if (info.filename.startswith(asset_dir)
                        and info.filename.lower().endswith(".jpg")):
                        continue
                    data = caml.encode() if info.filename == bp else base.read(info.filename)
                    out.writestr(info, data)

                for i in range(len(frames)):
                    name = asset_dir + str(i) + ".jpg"
                    path = os.path.join(resized, str(i) + ".jpg")
                    with open(path, "rb") as f:
                        out.writestr(name, f.read())

        with zipfile.ZipFile(output) as z:
            bad = z.testzip()
            final_caml = z.read(bp).decode()
            refs = re.findall(r'<CGImage src="([^"]+)"', final_caml)
            missing = [
                asset_dir + r.replace("assets/", "")
                for r in refs
                if asset_dir + r.replace("assets/", "") not in z.namelist()
            ]

        if bad or missing or len(refs) != len(frames):
            raise Exception("Final archive validation failed")

        with open(REPORT, "w") as f:
            f.write("OUTPUT: %s\nVIDEO: %s\n" % (output, video))
            f.write("VIDEO SIZE: %dx%d\n" % (width, height))
            f.write("OUTPUT FRAME SIZE: %dx%d\n" % SIZE)
            f.write("DURATION: %s\n" % duration)
            f.write("EXTRACTED FRAMES: %d\n" % len(frames))
            f.write("ANIMATION REFERENCES: %d\n" % len(refs))
            f.write("MISSING REFERENCES: %d\n" % len(missing))
            f.write("ZIP TEST: %s\nTEMPLATE SOURCE UNMODIFIED\n" % bad)
        print("BUILD COMPLETE")
        print("OUTPUT:", output)
        print("FRAMES:", len(frames))
        print("DURATION:", duration)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def menu():
    while True:
        os.system("clear")
        print("=" * 34)
        print("          MJ WALLPAPER")
        print("=" * 34)
        print("1. اختيار فيديو وتحويله")
        print("2. عرض الفيديوهات الموجودة")
        print("3. خروج")
        print("=" * 34)

        choice = input("اختيارك: ").strip()

        videos = []
        for ext in ("*.mp4", "*.MP4", "*.mov", "*.MOV",
                    "*.m4v", "*.M4V", "*.mkv", "*.MKV"):
            videos.extend(glob.glob("/mnt/files/" + ext))
        videos = sorted(set(videos))

        if choice == "3":
            break

        if choice == "2":
            print("\nالفيديوهات الموجودة:")
            for i, v in enumerate(videos, 1):
                print("%d. %s" % (i, os.path.basename(v)))
            input("\nاضغط Enter للعودة...")
            continue

        if choice == "1":
            if not videos:
                input("ماكو فيديوهات داخل /mnt/files. اضغط Enter...")
                continue

            print("\nاختر الفيديو:")
            for i, v in enumerate(videos, 1):
                print("%d. %s" % (i, os.path.basename(v)))

            try:
                number = int(input("\nرقم الفيديو: "))
                video = videos[number - 1]
                name = input("اسم الخلفية الناتجة (بدون امتداد): ").strip()
                if not name:
                    name = "MJ-Wallpaper"
                name = os.path.basename(name)
                if not name.endswith(".tendies"):
                    name += ".tendies"

                output = os.path.join("/mnt/files", name)

                if os.path.exists(output):
                    confirm = input("الملف موجود. استبداله؟ (y/n): ")
                    if confirm.lower() != "y":
                        continue

                print("\nبدأ التحويل...")
                build(video, output)
                print("\nتم إنشاء الخلفية بنجاح.")
                print("الملف:", output)
                print("التقرير:", REPORT)

            except (ValueError, IndexError):
                print("اختيار غير صحيح.")
            except Exception as e:
                print("فشل التحويل:", str(e))

            input("\nاضغط Enter للعودة للقائمة...")

        else:
            input("اختيار غير صحيح. اضغط Enter...")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        video = sys.argv[1]
        output = sys.argv[2] if len(sys.argv) > 2 else \
            "/mnt/files/Universal-Animated-Wallpaper.tendies"
        build(video, output)
    else:
        menu()
