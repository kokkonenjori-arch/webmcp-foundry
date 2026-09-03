"""tools/make_gif.py — compose the captured frames into a 3:2 split-screen GIF (Pillow only).

    python tools/make_gif.py [--size 1200x800] [--fps 10] [--out webmcp-foundry-demo.gif]

Left: Foundry capability state (console detail). Right: the page's native document.modelContext
registry (Ledgerly "Agent interface" panel). One caption. Global adaptive palette, frame
differencing (Pillow stores only the changed region of each frame), seamless loop via a short
crossfade back to the first frame. Time is compressed by keeping ~1.5 s before the event and
dropping unchanged stretches, so the story fits in 6–8 s.
"""
import json, sys, os
from PIL import Image, ImageDraw, ImageFont, ImageChops

args = dict(a.split('=', 1) for a in sys.argv[1:] if '=' in a)
W, H = map(int, args.get('--size', '1200x800').split('x'))
FPS = int(args.get('--fps', '10'))
OUT = args.get('--out', 'webmcp-foundry-demo.gif')
meta = json.load(open('media/frames.json'))
frames = meta['frames']
event_t = next(f['t'] for f in frames if f.get('event'))
removed_t = meta['removedAt']

BG, PANEL, LINE, INK, MUT, ACC, AMBER = (15, 18, 20), (23, 27, 31), (42, 48, 54), (230, 230, 226), (154, 160, 166), (92, 200, 168), (227, 176, 75)
def font(size, bold=False):
    for name in (['segoeuib.ttf', 'arialbd.ttf'] if bold else ['segoeui.ttf', 'arial.ttf']):
        p = os.path.join(os.environ.get('WINDIR', 'C:/Windows'), 'Fonts', name)
        if os.path.exists(p): return ImageFont.truetype(p, size)
    return ImageFont.load_default()
F_CAP, F_LAB, F_SUB = font(int(H * 0.048), True), font(int(H * 0.024), True), font(int(H * 0.021))

CAP_H = int(H * 0.19)          # caption band
LAB_H = int(H * 0.075)         # panel labels
PAD = int(W * 0.012)
PW = (W - 3 * PAD) // 2        # panel width
PH = H - CAP_H - LAB_H - 2 * PAD

def fit(im, w, h, bg=PANEL):
    """scale to the panel width (captures are 2x, so this is a downscale), centre vertically, crop if taller"""
    s = w / im.width
    im = im.resize((w, max(1, int(im.height * s))), Image.LANCZOS)
    canvas = Image.new('RGB', (w, h), bg)
    y = max(0, (h - im.height) // 2)
    canvas.paste(im.crop((0, 0, w, min(im.height, h))), (0, y))
    return canvas

def compose(fr, phase):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    # labels
    d.text((PAD, PAD + 4), 'FOUNDRY — capability state', font=F_LAB, fill=MUT)
    d.text((PAD, PAD + 4 + int(H * 0.032)), 'pure-Julia authority · ledger-backed', font=F_SUB, fill=(110, 116, 122))
    d.text((2 * PAD + PW, PAD + 4), 'BROWSER — native document.modelContext', font=F_LAB, fill=MUT)
    d.text((2 * PAD + PW, PAD + 4 + int(H * 0.032)), 'Edge 152 · WebMCP · the page\'s own getTools()', font=F_SUB, fill=(110, 116, 122))
    # panels
    L = fit(Image.open(fr['left']).convert('RGB'), PW, PH)
    R = fit(Image.open(fr['right']).convert('RGB'), PW, PH)
    y0 = PAD + LAB_H
    im.paste(L, (PAD, y0)); im.paste(R, (2 * PAD + PW, y0))
    d.rectangle([PAD - 1, y0 - 1, PAD + PW, y0 + PH], outline=LINE)
    d.rectangle([2 * PAD + PW - 1, y0 - 1, 2 * PAD + 2 * PW, y0 + PH], outline=LINE)
    # caption band
    cy = H - CAP_H
    d.rectangle([0, cy, W, H], fill=(11, 14, 16))
    d.line([0, cy, W, cy], fill=LINE)
    steps = [('Code changed', phase >= 1), ('evidence stale', phase >= 2), ('agent tool withdrawn', phase >= 3)]
    x = PAD; ty = cy + int(CAP_H * 0.22)
    for i, (txt, on) in enumerate(steps):
        col = (ACC if i == 2 else AMBER if i == 1 else INK) if on else (70, 76, 82)
        d.text((x, ty), txt, font=F_CAP, fill=col)
        x += d.textlength(txt, font=F_CAP) + int(W * 0.012)
        if i < 2:
            d.text((x, ty), '→', font=F_CAP, fill=(90, 96, 102)); x += d.textlength('→', font=F_CAP) + int(W * 0.012)
    d.text((PAD, cy + int(CAP_H * 0.68)), 'WebMCP Foundry · agents propose, evidence qualifies, authority promotes', font=F_SUB, fill=MUT)
    return im

# caption phases follow what is VISIBLE: the left crop changing after the event = STALE shown,
# the right crop changing after the event = the native registry lost the tool
def _first_change(key, after):
    ref = Image.open(next(f for f in frames if f['t'] >= after)[key]).convert('RGB')
    for f in frames:
        if f['t'] <= after: continue
        im = Image.open(f[key]).convert('RGB')
        if im.size != ref.size: return f['t']
        bb = ImageChops.difference(im, ref).getbbox()
        # a MEANINGFUL change: at least 3% of the crop's area (a badge or a whole line), not a report number
        if bb and (bb[2] - bb[0]) * (bb[3] - bb[1]) >= 0.03 * im.width * im.height: return f['t']
    return None
stale_visual_t = _first_change('left', event_t) or (event_t + 0.6)
removed_visual_t = _first_change('right', event_t) or removed_t
# Foundry acknowledging the browser's registry (the Browser card turning "consistent") may arrive a few
# seconds later (the page reports through the public tunnel); it is the natural final state if it exists
ack_t = _first_change('left', removed_t) if removed_t else None   # the Browser card updates right after Foundry records the report
final_t = ack_t if (ack_t and ack_t - removed_visual_t < 8) else removed_visual_t
print(f'event {event_t:.1f}s | STALE visible {stale_visual_t:.1f}s | tool gone (visible) {removed_visual_t:.1f}s | foundry ack {ack_t} | api-confirmed {removed_t:.1f}s')
def phase_of(t):
    if t < event_t: return 0
    if t >= removed_visual_t: return 3
    if t >= stale_visual_t: return 2
    return 1

# ---- time compression: keep 1.5 s before the event, everything until removal, 1.6 s after
PRE, POST = 2.0, 2.6   # seconds of hold before the code change and after the withdrawal
keep = [f for f in frames if event_t - PRE <= f['t'] <= final_t + POST]
# resample to FPS by time
start, end = keep[0]['t'], keep[-1]['t']
sampled = []
t = start
while t <= end + 1e-6:
    f = min(keep, key=lambda x: abs(x['t'] - t)); sampled.append((t, f)); t += 1.0 / FPS
# drop long unchanged stretches inside the transition (keep holds at both ends)
imgs = []
prev = None; same = 0
for (t, f) in sampled:
    im = compose(f, phase_of(t))
    if prev is not None and ImageChops.difference(im, prev).getbbox() is None:
        same += 1
        in_hold = t < event_t or t >= final_t
        cap = 8 if t >= removed_visual_t else 2   # show the withdrawn state ~0.9 s before Foundry's acknowledgement
        if not in_hold and same > cap: continue   # collapse dead time mid-transition
    else:
        same = 0
    imgs.append(im); prev = im
# seamless loop: 4-frame crossfade from the last frame back to the first
first, last = imgs[0], imgs[-1]
for k in range(1, 5):
    imgs.append(Image.blend(last, first, k / 5))

# ---- global palette from a mosaic of key frames, then quantize every frame with it
key = [imgs[0], imgs[len(imgs) // 2], imgs[-6]]
mosaic = Image.new('RGB', (W, H * len(key)))
for i, k in enumerate(key): mosaic.paste(k, (0, i * H))
pal = mosaic.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
q = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in imgs]
dur = int(round(1000 / FPS))
q[0].save(OUT, save_all=True, append_images=q[1:], duration=dur, loop=0, optimize=True, disposal=1)
size = os.path.getsize(OUT)
print(f'{OUT}: {W}x{H} ({W/H:.3f}:1) {len(q)} frames @ {FPS} fps = {len(q)/FPS:.1f} s, {size/1e6:.2f} MB')
# contact sheet for review
cols = 4; rows = (len(q) + cols - 1) // cols
sheet = Image.new('RGB', (cols * W // 4, rows * H // 4), BG)
for i, im in enumerate(imgs): sheet.paste(im.resize((W // 4, H // 4)), ((i % cols) * W // 4, (i // cols) * H // 4))
sheet.save('media/contact-sheet.png')
