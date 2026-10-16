---
name: gitlab-mr-hires-screenshots
description: Use when the user wants real screenshots of a GitLab MR (bot/review notes, description, labels, Jira links) for Slack, Jira, a deck or a demo, or says screenshots are "tiny", "low-res", "blurry" or "cut off". Captures from the user's signed-in Chrome via Claude in Chrome at native device resolution with larger text, stitches tall notes, saves PNG files. Also fits any long web page section that must be shared as a sharp image.
---

# Hi-res GitLab MR screenshots (Claude in Chrome + stitch)

Result on 2026-10-15 (PR-Agent demo, argocd !464 + clusters !16): **1485 px wide notes**, text 1.6× larger, whole notes in one image, pixel-exact stitching.
The first attempt (one shrunk zoom per note) was 647–1078 px, and the user rejected it as "tiny".
Script: `~/.claude/scripts/note-tile-stitch.py` (`--selftest`).

## Which browser
- **Built-in browser pane**: has no GitLab SSO session and lands on `users/sign_in`. I can't sign in. Ask the user to sign in there, or to say "use my Chrome".
- **Claude in Chrome** (user's signed-in Chrome): use it when the user says so. Load the tools in ONE ToolSearch: `tabs_context_mcp, navigate, computer, javascript_tool, browser_batch, tabs_close_mcp`. Open your own tab and close it at the end.
- macOS `screencapture` is useless here: the MCP Chrome window sat on a non-Retina second display (`screenY` = 982, LS24 2560×1440). Check `screenX/screenY` before trying it.

## Facts that drive the method
- `computer zoom` output is capped at about 1.2 MP. `save_to_disk` saves **exactly the returned image**, so `scale` < 1 also shrinks the saved file. Always use scale 1 (default) for anything you save.
- Zoom `region` is in the screenshot frame (e.g. 1483×812), not CSS px (`innerWidth` was 2016). frame = CSS × 1483/2016.
- A 742×406 frame region returns 1485×812 = native device pixels. Larger regions get downscaled. So tile the note column in 742×406 pieces.
- Text size comes from CSS: inject `body{zoom:1.6}`. GitLab reflows to a ~1000 CSS px column, so the text is 1.6× bigger at the same tile width.
- With CSS zoom, `scrollBy` units ≠ `getBoundingClientRect` units, so position iteratively (`__go` below). Always record the measured top.
- GitLab shows notes **newest first**: a bot reply sits ABOVE the command that triggered it. Capture reply top → command bottom.
- Diff-thread notes (`/add_docs`): the sticky file header covers the bot header. Anchor on the "started a thread" element instead.
- Newest notes can be missing until reload (`note_<id>` null): navigate again to `...#note_<id>`.
- Park the mouse in a corner first (`hover [1478,806]`) or the cursor lands in the shot.

## Steps
1. Get note ids from the API (`glab api projects/<pid>/merge_requests/<iid>/notes?sort=asc&per_page=100` → file). Pick bot notes and their command notes.
2. Open a tab, navigate to the MR, and inject the helpers with `javascript_tool` (edit `__T`):
```js
{const st=document.createElement('style');st.textContent='.top-bar-fixed,.merge-request-sticky,.issue-sticky-header{display:none!important} .super-sidebar{display:none!important} body{zoom:1.6}';document.head.appendChild(st);
window.__N=id=>document.getElementById('note_'+id);
window.__thread=id=>{let e=__N(id);while(e&&!(e.textContent||'').includes('started a thread'))e=e.parentElement;return [...e.querySelectorAll('*')].find(x=>x.children.length<6&&/started a thread/.test(x.textContent)&&x.getBoundingClientRect().height<80)||e};
window.__desc=()=>{const d=document.querySelector('.description');return [[...d.querySelectorAll('h1,h2,h3')].find(h=>/^\s*PR Type/.test(h.textContent)),d]};
window.__T={review:()=>[__N(BOT),__N(CMD)] /* , adddocs:()=>[__thread(BOT),__N(CMD)], describe:()=>__desc() */};
window.__go=(name,y)=>{const [a,b]=__T[name]();let k=1;for(let i=0;i<8;i++){const t=a.getBoundingClientRect().top;if(Math.abs(t-y)<1)break;window.scrollBy(0,(t-y)*k);const t2=a.getBoundingClientRect().top;if(t2!==t)k=k*(t-y)/(t-t2);}const A=a.getBoundingClientRect(),B=b.getBoundingClientRect();return JSON.stringify({n:name,t:Math.round(A.top*10)/10,b:Math.round(B.bottom*10)/10,l:Math.round(Math.min(A.left,B.left)),r:Math.round(Math.max(A.right,B.right))})};
JSON.stringify(Object.keys(__T).map(k=>JSON.parse(__go(k,8))))}
```
   The last line gives each target's height (`b - t`). Column `l..r` ≈ 448..1447 CSS → frame x 326..1068.
3. For each target, in one `browser_batch` per target:
   - Position k: `__go(name, 8 - 1000*k)`.
   - Zoom `[326,0,1068,406]` and `[326,406,1068,812]` with `save_to_disk: true`. The 2nd tile is not needed once the bottom is < 552 visual.
   - Repeat k until `8-1000k + height` ≤ 1104.
   - Record `{t, files}` per position and `b0` (bottom at k=0) in a JSON as you go. Tile files land in `~/.claude/projects/<proj>/<session>/tool-results/mcp-claude-in-chrome-blob-*.png`.
4. Header + labels: `window.scrollTo(0,0)`, then two zooms side by side `[320,60,902,560]` + `[902,60,1483,560]` → `hstack`.
5. Write spec.json with `scale = 1485/742 * 1483/innerWidth` (≈1.4722) and absolute tile paths, then `python3 ~/.claude/scripts/note-tile-stitch.py spec.json <out-dir>`.
6. Verify:
   - Build a seam sheet: crops ±90 px around each join `(t0-tk)*scale`, downscaled to JPEG ≤1000 px. Read it with `limit` (the Read hook trips on big PNGs).
   - Check sizes.
   - Keep the earlier set in `lowres-v1/` rather than deleting it.
7. Send with `SendUserFile` (`display: attach`), close the tab, and give the table file → what it shows.

## Output used for Slack (PR-Agent)
01 header+labels · 02 /help · 03 /describe · 04 /review + Ticket compliance · 05 /improve · 06 /update_changelog · 07 /add_docs · 08 /ask · 09-11 second repo.
Best 4 for a short post: review with Jira, "Partially compliant" example, Jira `/ask`, `/help`.
