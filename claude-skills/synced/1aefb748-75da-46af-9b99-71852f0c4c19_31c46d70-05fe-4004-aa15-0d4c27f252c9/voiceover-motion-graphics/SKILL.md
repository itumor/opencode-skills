---
name: "voiceover-motion-graphics"
description: "Use when building a procedural motion-graphics explainer video timed exactly to a supplied voice-over (Canvas 2D + Playwright + ffmpeg, phrase-level ASR timing, no captions)."
---

# Motion graphics timed to a voice-over

This pipeline produced the Agent Harness explainer: a 1920x1080 30 fps video, about 4.5 minutes long, with 11 scenes, every beat keyed to the narration and no captions. Everything runs in the cloud workspace with Python, Node-free Chromium (Playwright) and ffmpeg.

## Defaults (unless the user says otherwise)

- Do not generate captions or subtitles. On-screen text is limited to labels, numbers, short titles and code.
- Put the deliverables in `/mnt/user-data/outputs/` so they show in the Outputs sidebar. Use versioned names (`..._v2_...`) and keep earlier versions.
- The quality bar is premium enterprise keynote: dark navy background, soft glows, Poppins font, and motion that serves the narration.
- Send the user a one-line progress update at each phase (timing, scenes written, previews, render, mix). Long renders take 10+ minutes.

## 1. Ingest the voice-over

```bash
ffmpeg -y -i vo.mp3 -ar 48000 -ac 1 vo48.wav
ffmpeg -y -i vo.mp3 -ar 16000 -ac 1 vo16.wav
ffprobe -v error -show_entries format=duration -of csv=p=0 vo48.wav
```
Measure loudness now (see the narration-audio-mix skill, `meas.sh`) so you know what the mix needs. Video duration = VO length + about 3.5 s tail for the end card.

## 2. Get phrase-level timings (sherpa-onnx Whisper)

Do not use pocketsphinx. It matched only 259 of 537 script words. Use sherpa-onnx with Whisper small.en:

```bash
pip install sherpa-onnx --break-system-packages
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.en.tar.bz2
tar xjf sherpa-onnx-whisper-small.en.tar.bz2
```

Split by pauses, then transcribe each phrase. The result is exact start and end times plus text:

```python
import numpy as np, subprocess, json, sherpa_onnx
SR=48000; S=16000
load=lambda f,sr: np.frombuffer(subprocess.run(['ffmpeg','-loglevel','error','-i',f,'-ac','1','-ar',str(sr),'-f','f32le','-'],capture_output=True).stdout,dtype=np.float32)
x=load('vo48.wav',S); v=load('vo48.wav',SR).astype(np.float64)
w=int(.025*SR); e=np.array([20*np.log10(np.sqrt(np.mean(v[i:i+w]**2))+1e-9) for i in range(0,len(v)-w,w)])
a=e>-48                                   # speech frames
fill=int(.18/.025); i=0                   # close gaps < 0.18 s so words are not split
while i<len(a):
    if not a[i]:
        j=i
        while j<len(a) and not a[j]: j+=1
        if j-i<fill and i>0 and j<len(a): a[i:j]=True
        i=j
    else: i+=1
ph=[];s=None
for i,val in enumerate(a):
    if val and s is None: s=i
    if not val and s is not None: ph.append((s*.025,i*.025)); s=None
if s is not None: ph.append((s*.025,len(a)*.025))
d='sherpa-onnx-whisper-small.en/'
rec=sherpa_onnx.OfflineRecognizer.from_whisper(encoder=d+'small.en-encoder.int8.onnx',decoder=d+'small.en-decoder.int8.onnx',tokens=d+'small.en-tokens.txt',num_threads=2,language='en',task='transcribe')
out=[]
for a0,b0 in ph:
    seg=x[int(max(0,a0-.15)*S):int((b0+.15)*S)]
    st=rec.create_stream(); st.accept_waveform(S,seg); rec.decode_stream(st)
    out.append({'s':round(a0,3),'e':round(b0,3),'text':st.result.text.strip()})
json.dump(out,open('phrases.json','w'),indent=0)
for o in out: print('%7.2f-%7.2f %s'%(o['s'],o['e'],o['text']))
```
Print the phrase list and choreograph from it. A 4:21 VO gives about 130 phrases.

## 3. Choreograph the scenes

- Map every scene to a phrase range. Scenes overlap by 0.2 to 0.5 s for crossfades, for example S1 0 to 8.7, S2 8.2 to 18.4.
- Each visual beat starts on the phrase or word it illustrates, landing 0.1 to 0.2 s before the word.
- Keep each technical screen (counters, grids, code, scorecards) on screen for as long as the narrator talks about it. Do not cut away mid-explanation.
- Use one visual idea per spoken idea: counters roll up while the numbers are spoken, items appear one per spoken item, and cross-outs land on the word "not" or "no".
- Make the visual mood follow the voice. For example, desaturate (`mono`) during the failures section.

## 4. Engine and scene code (pure functions of time)

Files: `anim.html` (canvas plus fonts), `engine.js` (helpers), `scenes.js` (scenes plus `renderFrame`). The rules:

- Every frame is `renderFrame(t)`, a pure function of t. Use no `Math.random` and no `Date`; use a seeded `rnd(seed)` instead. This makes renders deterministic, so they can be split across workers and any frame can be previewed.
- Engine helpers: `W,H`, palette `C` (bg #060A16, ink #EEF3FF, dim #8793B8, orange #FF8A3D, blue #4DA3FF, cyan #5CE1E6, green #3DDC97, amber #FFC24B, red #FF5470, violet #9B7BFF); easing `E.out/in/io/back/elastic/expo`; `P(t,start,dur,ease)` progress 0 to 1; `F(t,a,b,fadeIn,fadeOut)` visibility window; `txt(s,x,y,{size,weight,color,align,alpha,ls,glow})`; `card(x,y,w,h,{fill,stroke,glow,glowColor})`; `chip`, `circ`, `ring`, `glow`, `line`, `poly`; `withT(x,y,scale,rot,fn,alpha)`; icon set `I.*`; and domain motifs (`drawBrain`, `drawHarness`). Reuse `/home/claude/mg2/engine.js` if it still exists.
- Scene pattern:
```js
function S5(t) {
  const on = F(t, 52.2, 107.9, .6, .6); if (on <= 0) return;
  g.save(); g.globalAlpha = on;
  const k = P(t, 63.1, .8, E.back);          // beat keyed to phrase start 63.1 s
  txt(String(Math.round(90 * P(t, 63.1, 1.6))), 960, 500, { size: 120, weight: 700, alpha: P(t, 63.1, .25) });
  g.restore();
}
const DUR = 264.4;
function renderFrame(t) {
  g.setTransform(1,0,0,1,0,0); g.globalAlpha = 1; g.globalCompositeOperation = 'source-over'; g.shadowBlur = 0;
  background(t);
  [S1, S2, S5].forEach(fn => { g.save(); fn(t); g.restore(); });
  vignette();
  const fo = 1 - P(t, DUR - 1.2, 1.1); if (fo < 1) { g.fillStyle = `rgba(0,0,0,${1-fo})`; g.fillRect(0,0,W,H); }
}
window.renderFrame = renderFrame;
window.ready = document.fonts.load('700 40px P').then(() => document.fonts.load('500 40px P')).then(() => true);
```
- Fonts: use `@font-face{font-family:P;src:url(file:///usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf);font-weight:700}` (and the same for 300/400/500), launch Chromium with `--allow-file-access-from-files`, and await `window.ready` before rendering.
- Size cards to their text. Measure with `g.font=...; g.measureText(label).width` and set the card width to `max(minW, textW + padding)`. A fixed width let "When must a human approve?" overflow its card.
- When cards would overlap, slide earlier cards aside as later ones arrive, using progress through the scene.
- Write scenes in two or three files (scenesA/B/C.js) and `cat` them into one `scenes.js`. This keeps each file editable.

## 5. Preview before rendering

```python
# preview.py t1 t2 ...  -> prev/f_0032.60.jpg
import sys,base64
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b=p.chromium.launch(args=['--allow-file-access-from-files'])
    pg=b.new_page(viewport={'width':1920,'height':1080})
    errs=[]; pg.on('pageerror',lambda e: errs.append(str(e)))
    pg.goto('file:///ABS/PATH/anim.html'); pg.evaluate('window.ready')
    for t in map(float,sys.argv[1:]):
        pg.evaluate(f'renderFrame({t})')
        d=pg.evaluate("document.getElementById('c').toDataURL('image/jpeg',0.85)")
        open(f'prev/f_{t:07.2f}.jpg','wb').write(base64.b64decode(d.split(',')[1]))
    print('errors:',errs[:5]); b.close()
```
Preview 3 or 4 frames per scene: the entrance, the busiest moment, and the moment before exit. Look at each one with Read. Check for text overflow, overlaps, illegible small text, counters that start before they are visible (fade them in with `P(t,start,.25)`), and empty frames. Fix, then re-preview. In the Agent Harness project this took about 40 frames.

## 6. Render in parallel

```python
# render.py WORKER NWORKERS  -> segW.mp4
import sys,base64,subprocess
from playwright.sync_api import sync_playwright
FPS=30; DUR=264.4; N=int(DUR*FPS)
w,k=int(sys.argv[1]),int(sys.argv[2]); a,b=N*w//k,N*(w+1)//k
ff=subprocess.Popen(['ffmpeg','-y','-loglevel','error','-f','image2pipe','-framerate',str(FPS),'-c:v','mjpeg','-i','-','-c:v','libx264','-preset','medium','-crf','17','-pix_fmt','yuv420p',f'seg{w}.mp4'],stdin=subprocess.PIPE)
with sync_playwright() as p:
    br=p.chromium.launch(args=['--allow-file-access-from-files'])
    pg=br.new_page(viewport={'width':1920,'height':1080})
    pg.goto('file:///ABS/PATH/anim.html'); pg.evaluate('window.ready')
    for i in range(a,b):
        d=pg.evaluate(f"(renderFrame({i/FPS}), document.getElementById('c').toDataURL('image/jpeg',0.93))")
        ff.stdin.write(base64.b64decode(d[23:]))
        if (i-a)%300==0: print(w,i-a,'/',b-a,flush=True)
    br.close()
ff.stdin.close(); ff.wait(); print('done',w)
```
Run `nohup python3 render.py 0 2 > r0.log 2>&1 &` and `nohup python3 render.py 1 2 > r1.log 2>&1 &`. Two workers render about 7,900 frames in roughly 10 to 12 minutes. Poll the logs with `tail -n1` and short sleeps. Build the audio mix while the render runs.

Concatenate the segments:
```bash
printf "file 'seg0.mp4'\nfile 'seg1.mp4'\n" > list.txt
ffmpeg -y -f concat -safe 0 -i list.txt -c copy video_only.mp4
```
If you change scene code after the render starts, delete the segments and re-render.

## 7. Mux and make a web version

```bash
ffmpeg -y -i video_only.mp4 -i final_mix_24.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 256k -ar 48000 -t $DUR -movflags +faststart full.mp4
ffmpeg -y -i full.mp4 -vf scale=1280:720 -c:v libx264 -preset slow -b:v 640k -maxrate 800k -bufsize 1600k -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 -movflags +faststart web.mp4
```
The full version is about 85 MB for 4:24 (about 2.3 Mbps). The web version is about 28 MB, which stays under 30 MB for chat preview.

## 8. Verify, then deliver

- Check duration and streams with `ffprobe` (h264 1920x1080 30 fps, AAC 48 kHz stereo).
- Pull 3 or more frames from the final MP4 (`ffmpeg -ss T -i full.mp4 -frames:v 1 x.jpg`) and look at them.
- Re-measure the audio on the decoded MP4 (see the narration-audio-mix skill).
- `/mnt/user-data/outputs` can be a symlink to an rclone mount, and a long `cp a && cp b && ...` chain can fail with exit code 1. Copy files one at a time, check each exit code, and compare `md5sum` of the source and the copy.
- Send the web version with `SendUserFile` (display: render). Name all files in the reply: full MP4, web MP4, voice master WAV, final mix WAV.
- Report the measured numbers honestly, and state what you did not check (for example, that you reviewed frames but did not watch the full video in real time).