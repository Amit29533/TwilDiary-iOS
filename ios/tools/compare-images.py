"""Explicit, reproducible comparison. Never stretch an image or silently hide differences.

python ios/tools/compare-images.py reference.png simulator.png output.png
Optional --native-insets TOP RIGHT BOTTOM LEFT removes only documented OS chrome.
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageStat, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument('reference', type=Path)
parser.add_argument('native', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--native-insets', nargs=4, type=int, default=[0, 0, 0, 0])
parser.add_argument('--native-scale', type=int, default=1, choices=[1, 2, 3])
args = parser.parse_args()
reference = Image.open(args.reference).convert('RGB')
native = Image.open(args.native).convert('RGB')
if args.native_scale != 1:
    if native.width % args.native_scale or native.height % args.native_scale:
        raise SystemExit('Native pixel dimensions must divide exactly by the declared device scale')
    native = native.resize((native.width // args.native_scale, native.height // args.native_scale), Image.Resampling.LANCZOS)
top, right, bottom, left = args.native_insets
if any(value < 0 for value in args.native_insets) or left+right >= native.width or top+bottom >= native.height:
    raise SystemExit('Invalid native OS-chrome insets')
native = native.crop((left, top, native.width-right, native.height-bottom))
width, height = max(reference.width, native.width), max(reference.height, native.height)
first = Image.new('RGB', (width,height), '#ff00ff'); first.paste(reference,(0,0))
second = Image.new('RGB', (width,height), '#ff00ff'); second.paste(native,(0,0))
difference = ImageChops.difference(first, second)
canvas = Image.new('RGB', (width*3, height+28), '#18151e')
draw = ImageDraw.Draw(canvas)
for i,(label,img) in enumerate([('Web reference',first),('Native screenshot',second),('Absolute difference',difference)]):
    draw.text((i*width+8,8),label,fill='white');canvas.paste(img,(i*width,28))
args.output.parent.mkdir(parents=True,exist_ok=True);canvas.save(args.output)
stats={'referenceSize':reference.size,'nativeSize':native.size,'sameDimensions':reference.size==native.size,'nativeScale':args.native_scale,'nativeInsets':args.native_insets,'meanAbsoluteChannelDifference':ImageStat.Stat(difference).mean,'identical':difference.getbbox() is None}
args.output.with_suffix('.json').write_text(json.dumps(stats,indent=2)+'\n')
print(json.dumps(stats))
