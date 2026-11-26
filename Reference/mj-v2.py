#!/usr/bin/env python3
import os
import json, sys, re, json, glob, zipfile, shutil, subprocess, tempfile
import datetime
import time

BASE = "/mnt/files/Video-B-anim.tendies"
REPORT = "/mnt/files/Universal-Video-Wallpaper-Report.txt"
SIZE = (468, 1013)

def run(cmd):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)

def build(video, output):
    import time

    started = time.time()
    timings = {}
    work = tempfile.mkdtemp(prefix="wallpaper-", dir="/mnt/files")

    progress_started = False

    def progress(percent, message):
        nonlocal progress_started

        if message == "Analyzing video...":
            overall, stage, label = 1, "1/5", "تحليل الفيديو"
        elif message == "Video analysis complete":
            overall, stage, label = 10, "1/5", "اكتمل تحليل الفيديو"
        elif message == "Preparing extraction...":
            overall, stage, label = 10, "2/5", "استخراج الإطارات"
        elif message == "Extracting video frames...":
            overall = 10 + int(max(0, min(100, (percent - 2) * 100 / 63)) * 0.55)
            stage, label = "2/5", "استخراج الإطارات"
        elif message in ("Preparing animation template...", "Writing wallpaper archive..."):
            overall, stage, label = 65, "3/5", "بناء الخلفية"
        elif message in ("Writing template files...", "Adding video frames..."):
            overall = 65 + int(max(0, min(100, (percent - 67) * 100 / 25)) * 0.20)
            stage, label = "3/5", "بناء الخلفية"
        elif message == "Validating wallpaper archive...":
            overall, stage, label = 85, "4/5", "فحص ملف الخلفية"
        elif message == "Validation complete":
            overall, stage, label = 97, "4/5", "اكتمل فحص الملف"
        elif message == "Saving report...":
            overall, stage, label = 98, "5/5", "إنهاء العملية وحفظ التقرير"
        elif message == "BUILD COMPLETE":
            overall, stage, label = 100, "5/5", "اكتملت العملية"
        else:
            overall, stage, label = percent, "جاري العمل", message

        filled = int(overall / 5)
        bar = "[" + "#" * filled + "-" * (20 - filled) + "] %3d%%" % overall
        heading = stage + " | " + label

        if not progress_started:
            print(heading)
            print(bar, end="", flush=True)
            progress_started = True
        else:
            print("\033[1A\r\033[2K" + heading +
                  "\n\033[2K" + bar, end="", flush=True)

        if overall >= 100:
            print()

    try:
        progress(1, "Analyzing video...")
        t = time.time()

        meta = json.loads(run([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate",
            "-show_entries", "format=duration",
            "-of", "json", video
        ]).stdout)

        duration = float(meta["format"]["duration"])
        stream = meta["streams"][0]
        width, height = stream["width"], stream["height"]
        fps = stream.get("avg_frame_rate", "unknown")
        timings["analysis"] = time.time() - t
        progress(10, "Video analysis complete")

        frames_dir = os.path.join(work, "frames")
        os.makedirs(frames_dir)
        pattern = os.path.join(frames_dir, "frame-%06d.jpg")

        progress(2, "Preparing extraction...")
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", video,
            "-map", "0:v:0",
            "-vf",
            "scale=468:1013:force_original_aspect_ratio=increase,crop=468:1013",
            "-vsync", "0",
            "-q:v", "2",
            "-progress", "pipe:1",
            "-nostats",
            pattern
        ]

        t = time.time()
        process = subprocess.Popen(
            cmd, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True,
            bufsize=1
        )

        for line in process.stdout:
            if line.startswith("out_time_ms="):
                try:
                    current = int(line.split("=", 1)[1]) / 1000000.0
                    percent = 2 + int(
                        min(1.0, current / max(duration, 0.001)) * 63
                    )
                    progress(percent, "Extracting video frames...")
                except:
                    pass

        error = process.stderr.read()
        code = process.wait()

        if code != 0:
            raise Exception("FFmpeg failed: " + error[-1000:])

        timings["extraction"] = time.time() - t
        frames = sorted(glob.glob(frames_dir + "/*.jpg"))

        if not frames:
            raise Exception("No video frames extracted")

        progress(65, "Preparing animation template...")
        t = time.time()

        base = zipfile.ZipFile(BASE, "r")
        names = base.namelist()
        bp = next(
            n for n in names
            if "Background" in n and n.endswith("main.caml")
        )

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
        progress(67, "Writing wallpaper archive...")

        total_items = len(base.infolist()) + len(frames)
        completed = 0

        with zipfile.ZipFile(
            output, "w", zipfile.ZIP_DEFLATED
        ) as out:

            for info in base.infolist():
                if (
                    info.filename.startswith(asset_dir)
                    and info.filename.lower().endswith(".jpg")
                ):
                    completed += 1
                    continue

                data = (
                    caml.encode("utf-8")
                    if info.filename == bp
                    else base.read(info.filename)
                )

                out.writestr(info, data)
                completed += 1

                percent = 67 + int(
                    completed / max(total_items, 1) * 25
                )
                progress(percent, "Writing template files...")

            for i, frame in enumerate(frames):
                name = asset_dir + str(i) + ".jpg"

                with open(frame, "rb") as f:
                    data = f.read()

                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_STORED
                out.writestr(info, data)

                completed += 1
                percent = 67 + int(
                    completed / max(total_items, 1) * 25
                )
                progress(percent, "Adding video frames...")

        timings["archive"] = time.time() - t

        progress(85, "Validating wallpaper archive...")
        t = time.time()

        with zipfile.ZipFile(output, "r") as z:
            bad = z.testzip()
            final_caml = z.read(bp).decode("utf-8")
            refs = re.findall(
                r'<CGImage src="([^"]+)"', final_caml
            )

            archive_names = set(z.namelist())

            missing = [
                asset_dir + r.replace("assets/", "")
                for r in refs
                if asset_dir + r.replace("assets/", "")
                not in archive_names
            ]

        if bad or missing or len(refs) != len(frames):
            raise Exception("Final archive validation failed")

        timings["validation"] = time.time() - t
        progress(97, "Validation complete")
        timings["total"] = time.time() - started

        progress(98, "Saving report...")
        stage_names = {
            "analysis": "تحليل الفيديو",
            "extraction": "استخراج الإطارات",
            "archive": "بناء الأرشيف",
            "validation": "فحص الخلفية",
            "total": "الوقت الإجمالي"
        }

        with open(REPORT, "w") as f:
            f.write("تقرير إنشاء الخلفية - MJ\n")
            f.write("========================\n")
            f.write("ملف الخلفية: %s\n" % output)
            f.write("الفيديو المصدر: %s\n" % video)
            f.write("أبعاد الفيديو الأصلي: %dx%d\n" % (width, height))
            f.write("أبعاد الخلفية: 468x1013\n")
            f.write("معدل الإطارات: %s\n" % fps)
            f.write("المدة: %s\n" % duration)
            f.write("عدد الإطارات: %d\n" % len(frames))
            f.write("مراجع الحركة: %d\n" % len(refs))
            f.write("المراجع المفقودة: %d\n" % len(missing))
            f.write("نتيجة فحص الأرشيف: %s\n" % ("سليم" if bad is None else "تالف: " + str(bad)))
            f.write("القالب الأصلي: دون تعديل\n")
            f.write("\nأوقات مراحل التنفيذ\n")
            for key, value in timings.items():
                label = stage_names.get(key, key)
                f.write("%s: %.2f ثانية\n" % (label, value))

        progress(100, "BUILD COMPLETE")
        print()
        print("ملف الخلفية:", output)
        print("عدد الإطارات:", len(frames))
        print("مدة الفيديو:", duration, "ثانية")
        print("ملف التقرير:", REPORT)
        print("الوقت الإجمالي: %.2f ثانية" % timings["total"])

    except Exception as e:
        print("\nفشل إنشاء الخلفية:", str(e))
        raise

    finally:
        try:
            base.close()
        except:
            pass
        shutil.rmtree(work, ignore_errors=True)

VERSION = "2.0.0"
LIBRARY = "/mnt/files/MJ-Library"
IMPORT_DIR = "/MJ-Wallpaper"
HISTORY = "/mnt/files/MJ-History.log"
REPORTS = "/mnt/files/MJ-Reports.jsonl"
SETTINGS = "/mnt/files/MJ-Settings.json"

def load_settings():
    global LIBRARY, IMPORT_DIR
    try:
        with open(SETTINGS, "r") as f:
            data = json.load(f)
        if isinstance(data, dict):
            lib = data.get("library")
            imp = data.get("import_dir")
            if isinstance(lib, str) and lib.strip():
                LIBRARY = lib.strip()
            if isinstance(imp, str) and imp.strip():
                IMPORT_DIR = imp.strip()
    except (OSError, ValueError):
        pass

def save_settings():
    data = {
        "library": LIBRARY,
        "import_dir": IMPORT_DIR
    }
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=4)

load_settings()
os.makedirs(IMPORT_DIR, exist_ok=True)
os.makedirs(LIBRARY, exist_ok=True)

def header():
    os.system("clear")
    c = "\033[96m"
    w = "\033[97m"
    m = "\033[95m"
    r = "\033[0m"

    print(c + "╔══════════════════════════════════════╗" + r)
    print(c + "║                                      ║" + r)
    print(c + "║                  MJ                  ║" + r)
    print(c + "║                                      ║" + r)
    print(c + "║             " + w + "WALLPAPER" + r + "                " + c + "║" + r)
    print(c + "║                                      ║" + r)
    print(c + "║        " + m + "ULTIMATE VIDEO ENGINE" + r + "         " + c + "║" + r)
    print(c + "║                                      ║" + r)
    print(c + "╚══════════════════════════════════════╝" + r)
    print()
    print("VERSION:", VERSION)
    print()

def get_videos(folder=None):
    if folder is None:
        folder = LIBRARY
    if not os.path.isdir(folder):
        return []
    extensions = (".mp4", ".mov", ".m4v", ".mkv", ".avi")
    result = []
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and name.lower().endswith(extensions):
            result.append(path)
    return result

def import_video():
    print("ضع الفيديو داخل مجلد الاستيراد:")
    print(IMPORT_DIR)
    print("الصيغ المدعومة: MP4, MOV, M4V, MKV, AVI")
    print()
    videos = get_videos(IMPORT_DIR)
    if not videos:
        print("مجلد استيراد الفيديوهات:")
        print(IMPORT_DIR)
        print("الصيغ المدعومة: MP4, MOV, M4V, MKV, AVI")
        print("ضع الفيديو داخل المجلد ثم أعد المحاولة.")
        input("\nاضغط Enter للمتابعة...")
        return

    for i, path in enumerate(videos, 1):
        print_video_summary(path, i)

    choice = input("\nرقم الفيديو (0 إلغاء): ").strip()
    if not choice.isdigit() or int(choice) == 0:
        return

    index = int(choice) - 1
    if index >= len(videos):
        print("اختيار غير صحيح.")
        return

    path = videos[index]
    show_video_info(path)
    confirm = input("\nاستيراد هذا الفيديو؟ (y/n): ").strip().lower()
    if confirm != "y":
        return

    os.makedirs(LIBRARY, exist_ok=True)
    destination = os.path.join(LIBRARY, os.path.basename(path))
    if os.path.abspath(path) == os.path.abspath(destination):
        print("الفيديو موجود بالفعل في المكتبة.")
    else:
        shutil.copy2(path, destination)
        print("تم استيراد الفيديو بنجاح.")
    input("\nاضغط Enter للمتابعة...")

def video_library():
    while True:
        videos = get_videos()
        if not videos:
            print("مكتبة الفيديو فارغة.")
            break

        for i, path in enumerate(videos, 1):
            print_video_summary(path, i)

        choice = input("\nرقم الفيديو (0 رجوع): ")
        if not choice.isdigit() or int(choice) == 0:
            break

        index = int(choice) - 1
        if index < 0 or index >= len(videos):
            print("اختيار غير صحيح.")
            continue

        path = os.path.abspath(videos[index])
        print("\n1. معلومات الفيديو")
        print("2. حذف الفيديو")
        print("0. رجوع")

        action = input("\nاختيارك: ").strip()

        if action == "1":
            show_video_info(path)
            input("\nEnter للمتابعة...")
        elif action == "2":
            root = os.path.abspath(LIBRARY)
            if os.path.commonpath([root, path]) != root:
                print("مسار غير مسموح.")
                continue
            confirm = input("تأكيد الحذف؟ (y/n): ").strip().lower()
            if confirm == "y":
                os.remove(path)
                print("تم حذف الفيديو من المكتبة.")


def print_video_summary(path, index):
    print("%d. %s" % (index, os.path.basename(path)))
    try:
        cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate:format=duration,size",
            "-of", "json", path
        ]
        data = json.loads(subprocess.check_output(cmd, text=True))
        stream = data["streams"][0]
        fmt = data.get("format", {})

        duration = float(fmt.get("duration", 0))
        size = int(fmt.get("size", os.path.getsize(path)))
        rate = stream.get("r_frame_rate", "0/1")
        parts = rate.split("/")
        fps = float(parts[0]) / float(parts[1]) if len(parts) == 2 and float(parts[1]) else 0

        print("   المدة: %.2f ثانية" % duration)
        print("   الدقة: %s × %s" % (stream["width"], stream["height"]))
        print("   معدل الإطارات: %.2f FPS" % fps)
        print("   الحجم: %.2f ميغابايت" % (size / 1048576))
    except Exception:
        print("   تعذرت قراءة معلومات الفيديو.")

def show_video_info(path):
    cmd = ["ffprobe", "-v", "quiet", "-print_format",
           "json", "-show_streams", "-show_format", path]
    try:
        data = json.loads(subprocess.check_output(cmd, text=True))
        stream = next(x for x in data["streams"]
                      if x.get("codec_type") == "video")
        fmt = data.get("format", {})
        fps = eval(stream["r_frame_rate"])
        duration = float(fmt.get("duration", 0))
        size = int(fmt.get("size", 0))

        print("\nمعلومات الفيديو")
        print("اسم الفيديو:", os.path.basename(path))
        print("المدة: %.2f ثانية" % duration)
        print("الدقة: %s × %s" %
              (stream["width"], stream["height"]))
        print("معدل الإطارات: %.2f" % fps)
        print("حجم الملف: %.2f ميغابايت" %
              (size / 1048576))
    except Exception as e:
        print("تعذرت قراءة معلومات الفيديو:", e)

def save_history(video, output, status,
                 duration=0, frames=0, elapsed=0):
    now = datetime.datetime.now()
    record = {
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "video": os.path.basename(video),
        "output": output,
        "status": status,
        "duration": duration,
        "frames": frames,
        "elapsed": elapsed
    }

    with open(HISTORY, "a") as f:
        f.write(json.dumps(
            record, ensure_ascii=False
        ) + "\n")


def save_report_archive(video, output):
    now = datetime.datetime.now()
    with open(REPORT, "r") as f:
        report = f.read()

    record = {
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "video": os.path.basename(video),
        "output": output,
        "report": report
    }

    fd, temp_path = tempfile.mkstemp(
        prefix=".MJ-Reports-",
        suffix=".tmp",
        dir=os.path.dirname(REPORTS)
    )

    try:
        with os.fdopen(fd, "w") as temp:
            if os.path.isfile(REPORTS):
                with open(REPORTS, "r") as old:
                    shutil.copyfileobj(old, temp)

            temp.write(json.dumps(record, ensure_ascii=False) + "\n")
            temp.flush()
            os.fsync(temp.fileno())

        os.replace(temp_path, REPORTS)

    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def show_history():
    while True:
        header()
        print("سجل عمليات التحويل")
        print("===================")

        if not os.path.isfile(HISTORY):
            print("لا توجد عمليات مسجلة.")
        else:
            with open(HISTORY, "r") as f:
                records = f.readlines()

            if not records:
                print("السجل فارغ.")
            else:
                for line in records:
                    try:
                        item = json.loads(line)
                        print("\nالتاريخ:", item["date"])
                        print("الوقت:", item["time"])
                        print("الفيديو:", item["video"])
                        print("الخلفية:", os.path.basename(
                            item["output"]
                        ))
                        print("الحالة:", item["status"])
                        print("المدة:", item["duration"])
                        print("الإطارات:", item["frames"])
                        print("وقت التنفيذ: %.2f ثانية" %
                              item["elapsed"])
                        print("-------------------")
                    except Exception:
                        print("سجل غير قابل للقراءة.")

        print("\n1. حذف جميع السجلات")
        print("0. رجوع")
        choice = input("\nاختيارك: ").strip()

        if choice == "0":
            return
        elif choice == "1":
            if not os.path.isfile(HISTORY):
                print("لا يوجد سجل للحذف.")
            else:
                confirm = input(
                    "تأكيد حذف جميع السجلات؟ (y/n): "
                ).strip().lower()

                if confirm == "y":
                    with open(HISTORY, "w") as f:
                        pass
                    print("تم حذف جميع السجلات.")
                else:
                    print("تم إلغاء الحذف.")

            input("\nاضغط Enter للمتابعة...")
        else:
            print("اختيار غير صحيح.")
            input("\nاضغط Enter للمتابعة...")


def show_reports():
    header()
    print("أرشيف التقارير")
    print("===================")

    if not os.path.isfile(REPORTS):
        print("لا توجد تقارير محفوظة.")
    else:
        with open(REPORTS, "r") as f:
            records = f.readlines()

        if not records:
            print("أرشيف التقارير فارغ.")
        else:
            for line in records:
                try:
                    item = json.loads(line)
                    print("\nالتاريخ:", item["date"])
                    print("الوقت:", item["time"])
                    print("الفيديو:", item["video"])
                    print("الخلفية:", os.path.basename(item["output"]))
                    print("-------------------")
                    print(item["report"])
                    print("===================")
                except Exception:
                    print("تقرير غير قابل للقراءة.")

    input("\nاضغط Enter للعودة...")
def browse_folder(start):
    current = os.path.abspath(start)

    while True:
        print("\033[2J\033[H", end="")
        print("\nالمجلد الحالي:")
        print(current)
        print("\nالمجلدات:")
        try:
            dirs = sorted(
                e.name for e in os.scandir(current)
                if e.is_dir(follow_symlinks=False)
            )
        except OSError as e:
            print("تعذر قراءة المجلد:", e)
            return None

        for i, name in enumerate(dirs, 1):
            print("%d. %s" % (i, name))

        print("\n0. اختيار هذا المجلد")
        print("u. المجلد السابق")
        print("n. إنشاء مجلد جديد")
        print("q. إلغاء والرجوع")
        choice = input("\nاختيارك: ").strip()

        if choice == "0":
            return current
        elif choice == "q":
            return None
        elif choice == "u":
            parent = os.path.dirname(current)
            if parent != current:
                current = parent
        elif choice == "n":
            name = input("اسم المجلد الجديد: ").strip()
            if name and name not in (".", ".."):
                if "/" not in name and "\\" not in name:
                    path = os.path.join(current, name)
                    try:
                        os.mkdir(path)
                        current = path
                    except OSError as e:
                        print("تعذر إنشاء المجلد:", e)
        elif choice.isdigit() and 1 <= int(choice) <= len(dirs):
            current = os.path.join(
                current, dirs[int(choice) - 1]
            )
        else:
            print("اختيار غير صحيح.")

def settings_menu():
    global LIBRARY, IMPORT_DIR
    while True:
        header()
        print("إعدادات الأداة")
        print("1. تغيير مجلد الاستيراد")
        print("2. تغيير مجلد المكتبة")
        print("0. رجوع")
        print()
        print("مسار الاستيراد:", IMPORT_DIR)
        print("مسار المكتبة:", LIBRARY)

        choice = input("\nاختيارك: ").strip()

        if choice == "0":
            return
        elif choice == "1":
            path = browse_folder(IMPORT_DIR)
        elif choice == "2":
            path = browse_folder(LIBRARY)
        else:
            print("اختيار غير صحيح.")
            input("اضغط Enter للمتابعة...")
            continue

        if path is None:
            continue

        if choice == "1":
            IMPORT_DIR = path
        else:
            LIBRARY = path

        save_settings()
        print("تم حفظ الإعدادات.")
        input("اضغط Enter للمتابعة...")


def check_dependencies():
    report = "/mnt/files/MJ-V2-Dependencies.txt"
    tools = ("ffmpeg", "ffprobe")

    def test_tool(name):
        if shutil.which(name) is None:
            return False, "غير مثبت"

        try:
            r = subprocess.run(
                [name, "-version"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                timeout=15
            )
            line = r.stdout.splitlines()
            version = line[0] if line else "لا توجد معلومات"

            if r.returncode == 0:
                return True, version

            return False, "فشل التشغيل: " + version

        except Exception as e:
            return False, "خطأ: " + str(e)

    header()
    green = "\033[92m"
    red = "\033[91m"
    reset = "\033[0m"

    print("Python Runtime".ljust(25) + green + "[ READY ]" + reset)

    results = {}
    for name, label in (
        ("ffmpeg", "FFmpeg Engine"),
        ("ffprobe", "FFprobe Engine")
    ):
        results[name] = test_tool(name)
        ok = results[name][0]
        status = green + "[ READY ]" if ok else red + "[ FAILED ]"
        print(label.ljust(25) + status + reset)

    bad = [name for name in tools if not results[name][0]]

    def write_report(mode):
        with open(report, "w") as f:
            f.write("MJ V2 - تقرير الاعتماديات\n")
            f.write("Python: %s\n" % sys.version)
            f.write("نتيجة الفحص: %s\n" % mode)

            for name in tools:
                ok, detail = results[name]
                f.write("%s: %s\n" % (
                    name, "سليم" if ok else "فشل"))
                f.write("التفاصيل: %s\n" % detail)

    write_report("سليم" if not bad else "يحتاج إصلاح")

    if not bad:
        print("\033[92mSYSTEM READY\033[0m")
        time.sleep(4)
        return True

    print("اعتماديات تحتاج إصلاح:", ", ".join(bad))
    choice = input("محاولة الإصلاح الآن؟ (y/n): ").strip().lower()

    if choice != "y":
        return False

    print("جارٍ إصلاح حزمة FFmpeg...")
    try:
        result = subprocess.run(["apk", "add", "ffmpeg"])
    except Exception as e:
        print("تعذر تشغيل مدير الحزم:", str(e))
        return False

    if result.returncode != 0:
        print("فشل تثبيت أو إصلاح FFmpeg.")

    results = {name: test_tool(name) for name in tools}
    bad = [name for name in tools if not results[name][0]]

    write_report("سليم بعد الإصلاح" if not bad else "فشل الإصلاح")

    print("نتيجة الفحص:",
          "سليم" if not bad else "غير مكتمل")

    return not bad


def reports_menu():
    while True:
        header()
        print("التقارير وسجل العمليات")
        print("======================")
        print("1. عرض أرشيف التقارير")
        print("2. عرض سجل عمليات التحويل")
        print("3. حذف جميع التقارير")
        print("4. حذف جميع سجلات العمليات")
        print("0. رجوع")

        choice = input("\nاختيارك: ").strip()

        if choice == "0":
            return
        elif choice == "1":
            show_reports()
        elif choice == "2":
            show_history()
        elif choice == "3":
            confirm = input("تأكيد حذف جميع التقارير؟ (y/n): ").strip().lower()
            if confirm == "y":
                with open(REPORTS, "w") as f:
                    pass
                print("تم حذف جميع التقارير.")
            else:
                print("تم إلغاء الحذف.")
            input("\nاضغط Enter للمتابعة...")
        elif choice == "4":
            confirm = input("تأكيد حذف جميع سجلات العمليات؟ (y/n): ").strip().lower()
            if confirm == "y":
                with open(HISTORY, "w") as f:
                    pass
                print("تم حذف جميع سجلات العمليات.")
            else:
                print("تم إلغاء الحذف.")
            input("\nاضغط Enter للمتابعة...")
        else:
            print("اختيار غير صحيح.")
            input("\nاضغط Enter للمتابعة...")
def main_menu():
    while True:
        header()
        print("1. استيراد فيديو")
        print("2. مكتبة الفيديو")
        print("3. إنشاء خلفية")
        print("4. التقارير وسجل العمليات")
        print("5. الإعدادات")
        print("6. خروج")
        choice = input("\nاختيارك: ").strip()

        if choice == "1":
            import_video()
        elif choice == "2":
            video_library()
        elif choice == "3":
            create_wallpaper()
        elif choice == "4":
            reports_menu()
        elif choice == "5":
            settings_menu()
        elif choice == "6":
            print("إلى اللقاء.")
            break
        else:
            print("اختيار غير صحيح.")
            input("\nاضغط Enter للمتابعة...")

def create_wallpaper():
    header()
    items = get_videos()

    if not items:
        print("مكتبة الفيديو فارغة.")
        input("اضغط Enter للعودة...")
        return

    print("إنشاء خلفية")
    for i, path in enumerate(items, 1):
        print_video_summary(path, i)

    choice = input("\nاختر الفيديو (0 رجوع): ").strip()
    if choice == "0":
        return
    if not choice.isdigit():
        return
    if not 1 <= int(choice) <= len(items):
        return

    video = items[int(choice) - 1]
    show_video_info(video)

    while True:
        name = input("اسم الخلفية بدون امتداد: ").strip()
        if not name or name in (".", ".."):
            print("اسم الخلفية غير صالح.")
            continue
        if any(c in name for c in ("/", "\\\\")):
            print("اسم الخلفية غير صالح.")
            continue
        if any(ord(c) < 32 for c in name):
            print("الاسم يحتوي محارف غير مسموحة.")
            continue

        output = os.path.join("/mnt/files", name + ".tendies")
        if os.path.exists(output):
            print("الاسم موجود، اختر اسماً آخر.")
            continue
        break

    confirm = input("إنشاء الخلفية؟ (y/n): ").strip().lower()
    if confirm != "y":
        print("تم إلغاء الإنشاء.")
        input("اضغط Enter للعودة...")
        return

    print("\nجارٍ إنشاء الخلفية...")
    started = time.time()

    try:
        build(video, output)
        elapsed = time.time() - started

        duration = 0
        frames = 0

        with open(REPORT, "r") as f:
            for line in f:
                if line.startswith("المدة:"):
                    duration = float(
                        line.split(":", 1)[1]
                    )
                if line.startswith("عدد الإطارات:"):
                    frames = int(
                        line.split(":", 1)[1]
                    )

        if os.path.isfile(output):
            save_history(
                video, output, "ناجحة",
                duration, frames, elapsed
            )
            save_report_archive(video, output)
            print("تم إنشاء الخلفية بنجاح:")
            print(output)
        else:
            save_history(
                video, output, "فاشلة",
                elapsed=elapsed
            )
            print("ملف الخلفية غير موجود.")

    except Exception as e:
        save_history(
            video, output, "فاشلة",
            elapsed=time.time() - started
        )
        print("فشل إنشاء الخلفية:", str(e))

    input("\nاضغط Enter للعودة...")

if __name__ == "__main__":
    if check_dependencies():
        main_menu()
