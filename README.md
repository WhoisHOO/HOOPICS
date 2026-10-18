# HOOPICS

<img src="HOO_Logo.jpg" alt="HOO logo" width="96" align="right" />

**Make blurry pictures big and sharp, sized for your exact screen.** Drop an image, pick where it
goes (your own screens, a laptop, a monitor, a phone), and HOOPICS enlarges it with AI and fits it
pixel-perfect.

Windows 10/11 · nothing to install · runs entirely on your PC · [MIT](./LICENSE) ·
[한국어 안내 (Korean)](./README.ko.md)

<p align="center"><img src="docs/screenshot-en.png" alt="The HOOPICS window" width="440" /></p>

| Enlarged the usual way | Enlarged with HOOPICS |
|---|---|
| <img src="docs/demo-before.png" alt="A 96 px logo enlarged with bicubic filtering: blurry and blocky" width="300" /> | <img src="docs/demo-after.png" alt="The same 96 px logo enlarged by HOOPICS: clean, sharp lines" width="300" /> |

---

## Quick start

1. **Code → Download ZIP**, then extract it anywhere. *You do not need Git or Python.*
2. Double-click **`start.bat`**, or drag images straight onto it.
3. Pick where the picture will be used and press **Start**.

Results are saved next to the original as `name_2560x1600.png` (or `name_x2.png` for "Enlarge by").
Nothing is ever overwritten; a second run makes `name_2560x1600 (2).png`.

The first run downloads the AI engine (about 43 MB) from the official
[Real-ESRGAN release](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0) and checks its
SHA-256 before using it. After that HOOPICS works offline.

> **"Windows protected your PC"?** `start.bat` is not code-signed, so SmartScreen may ask once.
> Click **More info → Run anyway**.

---

## What it does

| Option | |
|---|---|
| **My screens (auto)** | Detects every connected screen at its real pixel size and makes one image per screen. Tick *Set as desktop background* to apply each image to its own screen. |
| **Laptop / Monitor / Phone & tablet** | Common sizes: HD to 5K, 16:10, 3:2, ultrawide 21:9 and 32:9, MacBook, Galaxy, iPhone and iPad. |
| **Enlarge by** | 2×, 3× or 4×, keeping the shape. |
| **Custom** | Any width × height from 16 to 16384. |
| **Fill / Fit** | *Fill* crops evenly to the exact shape, like the Windows *Fill* wallpaper style. *Fit* keeps the whole picture over a blurred, dimmed copy of itself. |
| **Picture type** | Anime & illustration (default), an extra-sharp anime model, or photo. |

- Drop several images or a whole folder; every image gets the same settings.
- Reads JPG, PNG, WEBP, BMP, GIF and TIFF; saves PNG (lossless) or JPG.
- Phone photos stored sideways are turned upright (EXIF orientation); transparency is kept in PNG.
- Korean and English, picked from your Windows languages; switch any time with the button in the corner.

## Requirements

- Windows 10 or 11, 64-bit. PowerShell 5.1 and WPF, which HOOPICS is built on, ship with Windows.
- A graphics card with Vulkan support: practically any NVIDIA, AMD or Intel GPU with a current
  driver. If the AI step fails, update the graphics driver first.

---

## How it works

1. The picture is read, turned upright, and copied into a temporary folder whose path is
   ASCII-only. The engine crashes when its output path contains characters such as Hangul, which
   is common in Korean Windows user names.
2. [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) runs at its native 4× on the GPU through
   [ncnn and Vulkan](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan), twice in a row when more
   than 4× is needed (up to 16×).
3. The result is resampled to the exact target size with high-quality bicubic filtering, then
   cropped (*Fill*) or padded (*Fit*).

Running the 4× model and scaling down came out cleaner in our tests than the engine's own 3× model,
which left halos around outlines.

Screen sizes come from the Windows desktop-wallpaper API (`IDesktopWallpaper`), which reports real
pixels. With mixed display scaling, for example a 150% laptop next to a 100% monitor, a
system-DPI-aware program asking the usual screen APIs sees the second screen 1.5× too big.

## Command line

The window and the command line share one pipeline (`app/HOOPICS.Core.psm1`).

```powershell
# One image for a 2560x1600 screen
powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 photo.jpg -Size 2560x1600

# One image per connected screen, then set each as that screen's background
powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 art.png -Screens -SetWallpaper

# Every JPG in a folder, 2x, photo model, saved as JPG
powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 C:\pics\*.jpg -Scale 2 -Model photo -Format jpg
```

Other options: `-Model anime|anime-sharp|photo`, `-Mode fill|fit`, `-OutDir <folder>`.

## Project layout

| Path | |
|---|---|
| `start.bat` | Launcher: double-click it, or drop files on it |
| `app/HOOPICS.ps1` | The window: events, background worker, progress |
| `app/MainWindow.xaml` | Window layout (WPF) |
| `app/strings.json` | Every visible text, in Korean and English |
| `app/HOOPICS.Core.psm1` | Engine install, presets, screen detection, image pipeline |
| `app/Native.cs` | Win32/COM helpers: real screen sizes and per-screen wallpaper |
| `app/hoopics-cli.ps1` | Command line |
| `tests/` | Pester 5 tests; the engine is mocked, so no GPU is needed |
| `engine/` | Downloaded on first run, not in git |

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester -Path tests
```

Keep `.ps1`, `.psm1`, `.xaml` and `.cs` files ASCII-only: Windows PowerShell 5.1 reads files
without a BOM in the system code page. Put visible text in `app/strings.json`, in both languages;
a test checks that both have the same keys.

---

## Privacy

Everything runs on your PC. The only network request HOOPICS makes is the one-time engine
download from github.com.

## License

HOOPICS is released under the [MIT License](./LICENSE). The AI engine and models it downloads are
third-party open source: Real-ESRGAN (BSD 3-Clause), Real-ESRGAN-ncnn-vulkan (MIT), ncnn
(BSD 3-Clause) and libwebp (BSD 3-Clause). Their notices are in
[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md). HOOPICS is not affiliated with or endorsed by
their authors.
