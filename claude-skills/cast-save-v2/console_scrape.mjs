// Console truth pass for one cluster or an org list (ego-browser, signed-in EU console).
// Usage (via orchestrator): ego-browser nodejs < console_scrape.mjs
// Edit CL below, or keep single entry. Writes rows as JSON lines to stdout and full page
// texts to ./console-out/.
const task = await takeOverTaskSpace(parseInt(process.env.EGO_TASKSPACE || "13"));
const page = task.page(process.env.EGO_PAGE || "p2");
const fs = await import("node:fs/promises");
await fs.mkdir("console-out", { recursive: true });
const CL = JSON.parse(process.env.CLUSTERS_JSON || "[]");
// Each: [rank, name, orgId, clusterId]
const grab = (txt, re) => { const m = txt.match(re); return m ? m[1] : null; };
for (const [rank, name, org, cid] of CL) {
  const r = { rank, name };
  try {
    await page.goto(`https://console.eu.cast.ai/automation/external-clusters/${cid}/dashboard?org=${org}`);
    await page.waitForLoadState("domcontentloaded");
    await page.waitForTimeout(5000);
    const dash = await page.evaluate(() => document.body.innerText);
    await fs.writeFile(`console-out/${String(rank).padStart(2, "0")}-dash.txt`, dash);
    r.status = grab(dash, /(Connected|Disconnected|Warning|Degraded)/);
    r.nodes = grab(dash, /TOTAL NODES\s*\n?\s*([\d,]+)/);
    r.spot = grab(dash, /SPOT\s*\n?\s*([\d,]+)/);
    r.pods = grab(dash, /TOTAL PODS\s*\n?\s*([\d,]+)/);
    r.unsched = grab(dash, /UNSCHEDULED\s*\n?\s*([\d,]+)/);
    r.oom = grab(dash, /OOM KILLS\s*\n?\s*([\d,]+)/) ?? grab(dash, /TOTAL EVENTS\s*\n?\s*([\d,]+)/);
  } catch (e) { r.dashErr = String(e).slice(0, 100); }
  try {
    await page.goto(`https://console.eu.cast.ai/automation/external-clusters/${cid}/rebalance?org=${org}`);
    await page.waitForLoadState("domcontentloaded");
    await page.waitForTimeout(6000);
    const reb = await page.evaluate(() => document.body.innerText);
    await fs.writeFile(`console-out/${String(rank).padStart(2, "0")}-rebalance.txt`, reb);
    const m = reb.match(/([\da-f]{8})-[\da-f-]{27,}\s*\n([^\n]*)\s*\n(\d{4}-\d{2}-\d{2}[^\n]*)\s*\n([^\n]*)\s*\n\$([\d,.]+)\s*\nof \$([\d,.]+)/);
    if (m) { r.lastPlan = m[1]; r.lastSched = m[2]; r.lastWhen = m[3]; r.lastSave = m[5]; r.lastBase = m[6]; }
    else { r.never = /hasn't been rebalanced/i.test(reb) || undefined; }
  } catch (e) { r.rebErr = String(e).slice(0, 100); }
  console.log(JSON.stringify(r));
}
console.log("DONE");
