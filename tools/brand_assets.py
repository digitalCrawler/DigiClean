"""Builds every DigiClean icon and brand image from the brand sheet.

    python tools/brand_assets.py

Source: branding/brand-sheet.png (navy background, favicon tile on the left,
logo lockup on the right). The mark is cut out of the sheet by keying out
the navy background, then placed on clean navy tiles at each size, so icons
have crisp edges and no artefacts from the sheet. The generator's watermark
in the sheet's corner is never included. Requires Pillow.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SHEET = ROOT / "branding/brand-sheet.png"

NAVY = (17, 47, 71)  # #112F47
MINT = (111, 216, 176)  # #6FD8B0
WHITE = (255, 255, 255)

# Regions in the 2752x1536 sheet.
MARK_BOX = (367, 563, 826, 1002)  # the "D" + magnifier + dot inside the favicon tile
LOCKUP_BOX = (1050, 530, 2630, 1020)  # mark + wordmark + tagline


def key_out_navy(img: Image.Image) -> Image.Image:
    """Turns navy into transparency. Each pixel is modelled as a blend of navy
    and one of the brand colours (white or mint); the blend factor becomes
    alpha, so anti-aliased edges stay smooth on any tile colour."""
    src = img.convert("RGB")
    out = Image.new("RGBA", src.size)
    sp, op = src.load(), out.load()
    targets = [WHITE, MINT]
    dirs = [tuple(t[i] - NAVY[i] for i in range(3)) for t in targets]
    norms = [sum(d * d for d in v) for v in dirs]
    for y in range(src.height):
        for x in range(src.width):
            p = sp[x, y]
            dv = (p[0] - NAVY[0], p[1] - NAVY[1], p[2] - NAVY[2])
            best = None
            for t, v, n in zip(targets, dirs, norms):
                a = (dv[0] * v[0] + dv[1] * v[1] + dv[2] * v[2]) / n
                resid = sum((dv[i] - a * v[i]) ** 2 for i in range(3))
                if best is None or resid < best[0]:
                    best = (resid, a, t)
            _, a, t = best
            # Ignore the faint noise and lighting in the sheet's background.
            a = (a - 0.06) / 0.88
            a = max(0.0, min(1.0, a))
            op[x, y] = t + (round(a * 255),)
    return out


def mark() -> Image.Image:
    return key_out_navy(Image.open(SHEET).crop(MARK_BOX))


def tile(mark_img: Image.Image, size: int, radius_ratio: float, inset: float = 0.0,
         shadow: bool = False, opaque: bool = False, scale: float = 0.66) -> Image.Image:
    """Navy rounded tile with the mark centred. `inset` leaves transparent
    margin (macOS icon grid); `opaque` fills the corners (iOS)."""
    ss = 4
    s = size * ss
    canvas = Image.new("RGBA", (s, s), NAVY + (255,) if opaque else (0, 0, 0, 0))
    pad = round(s * inset)
    inner = s - 2 * pad
    radius = round(inner * radius_ratio)
    if shadow:
        sh_mask = Image.new("L", (s, s), 0)
        off = round(s * 0.012)
        ImageDraw.Draw(sh_mask).rounded_rectangle(
            [pad, pad + off, pad + inner, pad + inner + off], radius=radius, fill=90)
        sh = Image.new("RGBA", (s, s), (0, 0, 0, 255))
        sh.putalpha(sh_mask.filter(ImageFilter.GaussianBlur(s * 0.015)))
        canvas = Image.alpha_composite(canvas, sh)
    body = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle(
        [pad, pad, pad + inner - 1, pad + inner - 1], radius=radius, fill=NAVY + (255,))
    canvas = Image.alpha_composite(canvas, body)
    # Scale the mark to `scale` of the tile, keeping its aspect ratio.
    w, h = mark_img.size
    k = inner * scale / max(w, h)
    m = mark_img.resize((round(w * k), round(h * k)), Image.LANCZOS)
    canvas.alpha_composite(m, (pad + (inner - m.width) // 2, pad + (inner - m.height) // 2))
    out = canvas.resize((size, size), Image.LANCZOS)
    return out.convert("RGB") if opaque else out


def social_card() -> Image.Image:
    """1200x630 link preview: the logo lockup on navy."""
    card = Image.new("RGB", (1200, 630), NAVY)
    lockup = Image.open(SHEET).convert("RGB").crop(LOCKUP_BOX)
    k = 980 / lockup.width
    lockup = lockup.resize((980, round(lockup.height * k)), Image.LANCZOS)
    # Feather the crop edges into the flat navy so no seam shows.
    mask = Image.new("L", lockup.size, 0)
    ImageDraw.Draw(mask).rectangle([24, 24, lockup.width - 25, lockup.height - 25], fill=255)
    card.paste(lockup, ((1200 - lockup.width) // 2, (630 - lockup.height) // 2), mask.filter(ImageFilter.GaussianBlur(14)))
    return card


def main() -> None:
    m = mark()
    master = tile(m, 1024, radius_ratio=0.225)

    master.save(ROOT / "windows/runner/resources/app_icon.ico",
                sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    mac_dir = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    mac = tile(m, 1024, radius_ratio=0.225, inset=100 / 1024, shadow=True)
    for n in (16, 32, 64, 128, 256, 512, 1024):
        mac.resize((n, n), Image.LANCZOS).save(mac_dir / f"app_icon_{n}.png")

    ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    ios = tile(m, 1024, radius_ratio=0.0, opaque=True)
    for f in ios_dir.glob("Icon-App-*.png"):
        base, scale = f.stem.removeprefix("Icon-App-").split("@")
        n = round(float(base.split("x")[0]) * int(scale.rstrip("x")))
        ios.resize((n, n), Image.LANCZOS).save(f)

    for folder, n in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        tile(m, n, radius_ratio=0.225).save(ROOT / f"android/app/src/main/res/mipmap-{folder}/ic_launcher.png")

    brand = ROOT / "assets/branding"
    brand.mkdir(parents=True, exist_ok=True)
    master.resize((256, 256), Image.LANCZOS).save(brand / "app_icon.png")

    (ROOT / "packaging/linux").mkdir(parents=True, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(ROOT / "packaging/linux/digiclean.png")

    site = ROOT / "website/assets"
    site.mkdir(parents=True, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(site / "icon-512.png")
    tile(m, 180, radius_ratio=0.0, opaque=True).save(site / "apple-touch-icon.png")
    tile(m, 64, radius_ratio=0.225, scale=0.74).save(site / "favicon.png")
    social_card().save(site / "og-image.png", optimize=True)

    # Transparent mark (for use on navy only — the lens and "D" need it).
    m.save(ROOT / "branding/mark-on-navy.png")
    print("brand assets written")


if __name__ == "__main__":
    main()
