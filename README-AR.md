# MJ Wallpaper
المطوّر: @hamade_jmj — https://x.com/hamade_jmj

تطبيق iOS/iPadOS أصلي (SwiftUI) يحوّل الفيديو إلى خلفية `.tendies` متحركة، محلياً بالكامل، مجاني، بدون إعلانات.

## كيف تطلع MJ-Wallpaper.ipa (غير موقّع)
**السبب إننا ما نكدر نبنيه هنا:** بناء تطبيق iOS يحتاج macOS + Xcode. عندك طريقتين مجانيتين:

### أ) GitHub Actions (بدون Mac)
1. سوّي مستودع على GitHub وارفع محتوى هذا المجلد.
2. تبويب Actions ← "Build unsigned IPA" ← Run workflow.
3. نزّل `MJ-Wallpaper-ipa` من Artifacts. نفس الـ workflow يشغّل المحرك بالمحاكي ويقارن بالمحرك المرجعي (job اسمه selftest).

### ب) على Mac
```
brew install xcodegen
./tools/build_ipa.sh
```

## التثبيت
الـ IPA غير موقّع. وقّعه بنفسك (AltStore / Sideloadly / TrollStore / Xcode...) وثبّته.

## الاستخدام
المكتبة ← استيراد فيديو ← إنشاء ← اختر الفيديو والاسم ← إنشاء. النتيجة بمجلد MJ-Wallpapers داخل تطبيق الملفات (أو المجلد اللي تختاره بالإعدادات) ومشاركة مباشرة.

## المتطلبات
Xcode 15+، XcodeGen، لا مكتبات خارجية بالتطبيق (AVFoundation, ImageIO, Compression, SwiftUI, PhotosUI). Deployment target = iOS 14.0 (غير مؤكد بالاختبار).
