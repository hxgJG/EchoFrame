#!/usr/bin/env python3
"""使用 macOS 自带 sips，从确认的方形 PNG 同步各平台图标。"""

import argparse
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets/branding/lumio_app_icon_master.png"


def image_info(path):
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return dict(
        line.strip().split(": ", 1)
        for line in result.stdout.splitlines()
        if ": " in line
    )


def resize(source, target, size):
    subprocess.run(
        ["sips", "-s", "format", "png", "-z", str(size), str(size), str(source),
         "--out", str(target)],
        check=True,
        capture_output=True,
    )
    info = image_info(target)
    if info != {"pixelWidth": str(size), "pixelHeight": str(size), "hasAlpha": "no"}:
        raise ValueError(f"图标尺寸或透明通道不符合要求：{target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=MASTER)
    args = parser.parse_args()
    source = args.source.resolve()
    info = image_info(source)
    if info.get("pixelWidth") != info.get("pixelHeight") or info.get("hasAlpha") != "no":
        parser.error("请使用无透明通道的方形母图，以保留已确认的满铺背景。")
    if int(info["pixelWidth"]) < 1024:
        parser.error("母图不能小于 1024 × 1024。")
    if source != MASTER:
        resize(source, MASTER, 1024)

    targets = {ROOT / "assets/branding/lumio_logo_128.png": 128}
    for platform in ("ios", "macos"):
        folder = ROOT / platform / "Runner/Assets.xcassets/AppIcon.appiconset"
        manifest = json.loads((folder / "Contents.json").read_text())
        for entry in manifest["images"]:
            size = round(float(entry["size"].split("x")[0]) * float(entry["scale"][:-1]))
            targets[folder / entry["filename"]] = size
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        targets[ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"] = size
    for relative in (
        "ohos/AppScope/resources/base/media/app_icon.png",
        "ohos/entry/src/main/resources/base/media/icon.png",
    ):
        targets[ROOT / relative] = 114
    for target, size in targets.items():
        resize(MASTER, target, size)
    print(f"已同步并验证 {len(targets)} 个图标资源（母版：{MASTER}）。")


if __name__ == "__main__":
    main()
