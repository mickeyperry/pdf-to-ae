# pdf-to-ae

Right-click a PDF in Windows Explorer and drop its pages next to it as a numbered
image sequence — ready for After Effects to import as a single footage item.

No dialogs to click through, no Acrobat, no online converter. One right-click.

```
Board.pdf
Board_png300\
    Board_0001.png
    Board_0002.png
    Board_0003.png
```

## Install

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/mickeyperry/pdf-to-ae/main/install.ps1 | iex
```

Or download / clone the repo and double-click **`Install.cmd`**.

Either way it is a per-user install — no admin rights, nothing written outside
`HKCU` and your own profile. [Poppler](https://github.com/oschwartz10612/poppler-windows)
is fetched automatically via winget if you don't already have it.

## Use

Right-click any `.pdf`. On Windows 11 the entry sits under **Show more options**
(or press `Shift+F10` to open that menu directly).

**Extract pages for After Effects** →

| Preset | What you get |
|---|---|
| **PNG — 300 DPI, transparent** | Lossless, real alpha channel. The default. |
| **PNG — 600 DPI, transparent** | For artwork you'll scale up inside AE. |
| **PNG — 300 DPI, white backing** | Page background flattened to white. |
| **JPEG — 300 DPI** | Smaller files, no alpha, quality 95. |
| **Vector pages — one PDF per page** | Stays vector. Scales infinitely in AE. |
| **Custom…** | Pick format, DPI and transparency yourself. |

Output always lands in a subfolder beside the source PDF. The folder name carries
the settings — `_png300`, `_png600`, `_jpg300`, `_png300_opaque`, `_pdfpages` —
so running two presets on the same PDF never overwrites anything.

## Importing into After Effects

**Image sequence** — `File > Import > File`, select the **first** frame, tick
**PNG Sequence**, Import. Every page arrives as one footage item, a page per frame.

**Individual pages** — select them all and import normally.

**Vector pages** — import the PDFs, then switch on **Continuous Rasterize** (the
sun icon in the timeline) so they stay razor sharp at any scale.

## Which format?

**PNG** is the default for a reason: JPEG has no alpha channel, so a logo or title
card on a transparent page arrives with a white box baked in behind it — annoying
to composite. PNG keeps the transparency.

**Vector pages** are often the better answer for logos, typography and vector
boards. There's no resolution decision at all, and with Continuous Rasterize on
they stay sharp however far you scale them.

Pages render at a DPI, so pixel size follows page size. A4 works out roughly:

| DPI | Pixels |
|---|---|
| 150 | 1240 × 1754 |
| 300 | 2480 × 3508 |
| 600 | 4960 × 7016 |

600 DPI on a large page makes very heavy frames. Use it only when you genuinely
need to scale up — otherwise reach for the vector option.

## Uninstall

Double-click **`Uninstall.cmd`**, or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\uninstall-context-menu.ps1
```

That removes these two keys and nothing else:

```
HKCU\Software\Classes\SystemFileAssociations\.pdf\shell\PdfToAE
HKCU\Software\Classes\PdfToAE.Menu
```

Poppler and the script files stay on disk; remove them yourself if you want them gone.

## How it works

| File | Role |
|---|---|
| `install.ps1` | Dual-mode installer — web one-liner or local. Fetches Poppler if needed. |
| `src\pdf-to-ae.ps1` | The worker. Renders one page at a time so progress is real and filenames are exact. |
| `src\install-context-menu.ps1` | Writes the cascading submenu into `HKCU`. |
| `src\uninstall-context-menu.ps1` | Removes it. |

Rendering is [Poppler](https://poppler.freedesktop.org/): `pdftocairo` for raster
output (it, not `pdftoppm`, is the one with real `-transp` alpha support),
`pdfseparate` for the vector split, `pdfinfo` for the page count.

Each page is rendered as its own single-page call, which means files are named
`name_0001.png` directly — no post-rename pass, and a genuine progress bar on
long documents.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (ships with Windows)
- Poppler — installed for you by the installer

## License

MIT
