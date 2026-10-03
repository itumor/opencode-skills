---
name: "narration-audio-mix"
description: "Use when mixing a narration voice-over for a video or demo: hit a loudness target, keep pauses clean, place sparse ducked effects only in pauses, write 24-bit masters and AAC, verify on the decoded file."
---

# Narration audio mix

This applies to motion-graphics explainers and to screen-recorded demos with a voice-over. The voice is the product. Everything else stays out of its way.

## Default spec (Ebrahim's spec for the Agent Harness explainer; reuse it unless told otherwise)

- Integrated loudness about -17 LUFS (aim -17.0 to -17.8). True peak at or below -1 dBTP (aim about -2.5).
- Voice processing: a 70 Hz high-pass (rumble only), gain, and a transparent peak limiter if needed. No EQ, no reverb, no broadband compression, and no added noise or dither hiss.
- No music, no ambience, and no continuous beds or drones.
- Effects are short transients (whoosh, low thud, click, two-tone confirm). They sit only in the voice pauses at scene changes, 14 to 20 dB below the narration RMS, and are ducked by the voice.
- Ducking: voice-activity threshold about -50 dBFS, hold 120 ms, attack 8 ms, release 350 ms, depth -30 dB.
- Dual-mono stereo (L = R, centred, no widening).
- Masters: 48 kHz 24-bit WAV, both a voice-only mono master and the final stereo mix. Delivery: AAC 256 kbps in the MP4 (192 kbps for the web version).

Before delivering, check every number in the spec against a measurement. On the v2 explainer, effects shipped about 12 dB below the narration with a 120 ms release, against a spec of 14 to 20 dB and 350 ms. Measure that, not just "below the voice".

## 1. Measure the input

```bash
# meas.sh FILE  -> " I: -17.7 LUFS LRA: 3.7 LU Peak: -2.5 dBFS"
ffmpeg -hide_banner -nostats -i "$1" -af "ebur128=peak=true" -f null - 2>&1 | awk '/Summary:/{f=1} f' | grep -E "I:|LRA:|Peak:" | tr -s ' ' | paste -sd' '
```
Also listen for, or measure, the noise in the pauses: frame RMS more than 200 ms away from any speech.

## 2. Choose the voice path

**Clean TTS (ElevenLabs).** The pauses are already digital silence. Apply gain plus a look-ahead limiter only, with no gate. ElevenLabs delivered at -26.2 LUFS; +5.7 dB plus a -2.6 dBFS limiter gave -17.7 LUFS and -2.5 dBTP. First count how many peaks the limiter will touch (aim for isolated events, under about 100 in 4 minutes):
```python
y=x*10**(gdb/20); lim=10**(-2.6/20); idx=np.where(np.abs(y)>lim)[0]
events=1+np.sum(np.diff(idx)>int(.02*SR)) if len(idx) else 0
```
The chain:
```
ffmpeg -i vo.mp3 -af "highpass=f=70,aresample=48000:resampler=soxr,volume=5.7dB,alimiter=limit=0.74131:attack=5:release=70:level=disabled" -ac 1 -ar 48000 -f f32le -
```

**Noisy TTS (for example Gemini or AI Studio exports with hiss in the pauses).** Use a gentle downward expander keyed on the 200 to 3500 Hz band: threshold about -48 dBFS, 40 ms look-ahead, about 160 ms hold, floor -40 dB, open in 4 ms, close in 90 ms. Then run two-pass loudnorm (I=-17, TP=-1.5) or plain gain. Check that the speech RMS is unchanged (within 0.1 dB) and that the pause floor dropped. Use this path only when the user has not ruled out gating.

## 3. Effects, placed in pauses (numpy)

```python
rng=np.random.default_rng(11)
def env_exp(m,tau): return np.exp(-np.arange(m)/SR/tau)
def fade(x,fi=.004,fo=.02):
    x=x.copy(); a=int(fi*SR); b=int(fo*SR); x[:a]*=np.linspace(0,1,a); x[-b:]*=np.linspace(1,0,b); return x
def tone(f,dur,tau): m=int(dur*SR); t=np.arange(m)/SR; return fade(np.sin(2*np.pi*f*t)*env_exp(m,tau))
def whoosh(dur=.5):                     # band-passed noise with a sweeping cutoff
    m=int(dur*SR); x=rng.standard_normal(m); tt=np.arange(m)/m; y=np.zeros(m); s1=s2=0.0
    for k in range(m):
        c=.015+.16*np.sin(np.pi*tt[k]); s1+=c*(x[k]-s1); s2+=c*(s1-s2); y[k]=s1-s2
    y*=np.sin(np.pi*tt)**2; return fade(y/np.max(np.abs(y)),.03,.1)
def thud(f=100,dur=.4):
    m=int(dur*SR); t=np.arange(m)/SR; ph=2*np.pi*np.cumsum(f*(1+.8*np.exp(-t*25)))/SR
    return fade(np.sin(ph)*env_exp(m,.11),.002,.05)
def click(dur=.12):
    m=int(dur*SR); t=np.arange(m)/SR
    return fade((np.sin(2*np.pi*2400*t)+.5*np.sin(2*np.pi*3600*t))*env_exp(m,.018),.001,.03)
def confirm(d=.3):
    return np.concatenate([tone(1320,.09,.03),np.zeros(int(.04*SR)),tone(1760,.14,.05)]) if d>=.3 else tone(1760,max(.1,d),.04)
```
Placement uses `act` (a 20 ms RMS envelope of the un-limited voice above -52 dBFS) and `quiet` (no activity within 100 ms):
```python
def gap_for(t):                          # pause that contains or follows t
    j=max(0,int(t*SR)-int(.05*SR))
    while j<n-1 and not quiet[j]: j+=1
    a=j
    while a>0 and quiet[a-1]: a-=1
    c=j
    while c<n-1 and quiet[c]: c+=1
    return a/SR,c/SR
def place(buf,mk,t,rel_db):
    g0,g1=gap_for(t); x=mk(max(.1,min(.55,g1-g0-.04))); L=len(x)/SR
    st=max(min(max(t,g0+.02),g1-.02-L),g0+.01)
    x=x/np.sqrt(np.mean(x**2))*speech_rms*10**(rel_db/20)
    i=int(st*SR); buf[i:i+len(x)]+=x[:n-i]
    print(f'{t:7.2f} -> {st:7.2f}-{st+L:7.2f} (pause {g0:.2f}-{g1:.2f})')
```
- Take the target times from the video's scene changes (whooshes), impacts and verdicts (thuds), UI moments (clicks), and positive results (confirms). Use about 20 effects in 4 minutes. Fewer is better.
- Effects are shortened to fit the pause and never overlap speech. Read the printed placement log.
- Set `rel_db` so the measured result lands 14 to 20 dB under the narration RMS. Start at about -16 and measure, because the RMS normalisation of short transients reads hot.

## 4. Ducking (deterministic one-pole envelope)

```python
hold=np.convolve(act,np.ones(int(.08*SR)),'same')>0
tgt=np.where(hold,10**(-30/20),1.0); duck=np.ones(n); gcur=1.0
a_att=1-np.exp(-1/(.008*SR)); a_rel=1-np.exp(-1/(.35*SR))
for i in range(n):
    gcur+=(a_att if tgt[i]<gcur else a_rel)*(tgt[i]-gcur); duck[i]=gcur
fx*=duck; mix=voice+fx
```

## 5. Write the 24-bit WAVs

```python
def wav24(path,arr,ch):
    x=(np.clip(arr,-1,1)*8388607).astype(np.int32).reshape(-1)
    b=np.empty((len(x),3),np.uint8); b[:,0]=x&255; b[:,1]=(x>>8)&255; b[:,2]=(x>>16)&255
    w=wave.open(path,'wb'); w.setnchannels(ch); w.setsampwidth(3); w.setframerate(48000); w.writeframes(b.tobytes()); w.close()
wav24('final_mix_24.wav',np.stack([mix,mix],1),2)   # dual-mono
wav24('voice_master_24.wav',voice,1)
```
Make the mix exactly the video duration long (pad with zeros) so the mux with `-t DUR` lines up.

## 6. Verify on the decoded delivery file (after AAC)

1. Run `meas.sh full.mp4`. Integrated LUFS and peak must be within spec.
2. Check the pause floor. Decode with `ffmpeg -i full.mp4 -vn -ac 1 -ar 48000 -f f32le -` and take 100 ms frames that are at least 200 ms from speech and have no effects. The median should be digital silence or below -70 dBFS.
3. Check the effects level. Compare the loudest effect frame RMS with the narration RMS and confirm it is inside the 14 to 20 dB window.
4. Check the tail after the last word: silence or the end-card effect only.
5. Report the real numbers to the user. If one is outside the spec, say so and offer a remix. Do not round it into compliance.