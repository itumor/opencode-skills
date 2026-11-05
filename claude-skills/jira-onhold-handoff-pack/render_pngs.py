"""render_pngs.py <pack-dir> <scratch-dir> KEY [KEY...] -> <KEY>-diagram.png per key via mermaid-cli.
Source: <KEY>-diagram.mmd, else first ```mermaid block in <KEY>.md. Sequential on purpose:
parallel agents sharing one temp .mmd path overwrote each other's PNGs (2026-10-29).
A long 'flowchart LR' chain renders ~2000x110 (unreadable) -> rewritten to TD when >6 arrows."""
import re, subprocess, sys, pathlib, json
d = pathlib.Path(sys.argv[1]); scratch = pathlib.Path(sys.argv[2])
pp = scratch / "pp.json"  # bundled puppeteer Chrome missing on this Mac -> system Chrome
pp.write_text(json.dumps({"executablePath": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "args": ["--no-sandbox"]}))
for k in sys.argv[3:]:
    mmd = d / f"{k}-diagram.mmd"
    if mmd.exists():
        src = mmd.read_text()
    else:
        m = re.search(r"```mermaid\n(.*?)```", (d / f"{k}.md").read_text(), re.S)
        if not m:
            print(k, "NO MERMAID"); continue
        src = m.group(1)
    if "subgraph" not in src and src.count("-->") > 6:
        src = src.replace("flowchart LR", "flowchart TD", 1)
    tmp = scratch / f"{k}.mmd"; tmp.write_text(src)
    out = d / f"{k}-diagram.png"
    r = subprocess.run(["npx", "-y", "-p", "@mermaid-js/mermaid-cli@11.4.2", "mmdc", "-p", str(pp), "-i", str(tmp),
                        "-o", str(out), "-w", "2000", "-b", "white"], capture_output=True, text=True)
    print(k, "rc", r.returncode, out.stat().st_size if out.exists() else 0, r.stderr.strip()[-200:])
