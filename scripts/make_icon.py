#!/usr/bin/env python3
"""Generate the macOS app icon (development helper, not an app dependency)."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
SCALE = 4
SIZE = 1024
PIXELS = SIZE * SCALE


def sc(value: float) -> int:
    return int(round(value * SCALE))


def rounded_gradient(size: int, radius: int, top: tuple, bottom: tuple) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gradient = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (size, y)], fill=color + (255,))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    image.paste(gradient, (0, 0), mask)
    return image


def main() -> None:
    RESOURCES.mkdir(exist_ok=True)

    # Soft outer shadow.
    shadow = Image.new("RGBA", (PIXELS, PIXELS), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [sc(56), sc(66), sc(968), sc(978)],
        radius=sc(214),
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(24)))
    canvas = Image.new("RGBA", (PIXELS, PIXELS), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)

    card = rounded_gradient(
        PIXELS,
        sc(214),
        (18, 29, 44),
        (7, 12, 20),
    )
    inset = Image.new("L", (PIXELS, PIXELS), 0)
    ImageDraw.Draw(inset).rounded_rectangle(
        [sc(56), sc(56), sc(968), sc(968)], radius=sc(214), fill=255
    )
    canvas.paste(card, (0, 0), inset)

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        [sc(58), sc(58), sc(966), sc(966)],
        radius=sc(212),
        outline=(42, 58, 80, 255),
        width=sc(3),
    )

    center = (SIZE // 2 * SCALE, SIZE // 2 * SCALE)
    radius = sc(292)
    # Split status ring: red left arc, green right arc.
    bbox = [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius]
    draw.arc(bbox, start=100, end=260, fill=(255, 77, 94, 255), width=sc(30))
    draw.arc(bbox, start=280, end=80, fill=(53, 224, 140, 255), width=sc(30))

    # Microphone.
    mic_w = sc(92)
    mic_top = sc(292)
    mic_bottom = sc(562)
    draw.rounded_rectangle(
        [center[0] - mic_w // 2, mic_top, center[0] + mic_w // 2, mic_bottom],
        radius=mic_w // 2,
        fill=(248, 250, 252, 255),
    )
    arc_box = [
        center[0] - sc(160),
        center[1] - sc(130),
        center[0] + sc(160),
        center[1] + sc(200),
    ]
    draw.arc(arc_box, start=18, end=162, fill=(248, 250, 252, 255), width=sc(30))
    draw.rounded_rectangle(
        [center[0] - sc(16), sc(710), center[0] + sc(16), sc(790)],
        radius=sc(16),
        fill=(248, 250, 252, 255),
    )
    draw.rounded_rectangle(
        [center[0] - sc(116), sc(780), center[0] + sc(116), sc(812)],
        radius=sc(16),
        fill=(248, 250, 252, 255),
    )

    icon = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(RESOURCES / "AppIcon-1024.png")

    iconset = RESOURCES / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale_name, multiplier in (("", 1), ("@2x", 2)):
            name = f"icon_{size}x{size}{scale_name}.png"
            pixels = size * multiplier
            icon.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
    print("Wrote", RESOURCES / "AppIcon-1024.png")
    print("Wrote iconset:", iconset)


if __name__ == "__main__":
    main()
