#!/usr/bin/env python3
"""Tiny Streamable-HTTP MCP client (stdlib only) for the local ascender-mcp.
  python3 -I mcp_client.py tools [name-filter]             # list tools (+ schema when filtered)
  python3 -I mcp_client.py call TOOL '{"json":"args"}'     # call one tool
  python3 -I mcp_client.py --selftest
Token comes from env MCP_TOKEN (never printed). URL from MCP_URL (default http://127.0.0.1:8080/mcp)."""
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("MCP_URL", "http://127.0.0.1:8080/mcp")


def parse(body, ctype):
    """A response is plain JSON or an SSE stream; return the JSON-RPC message that carries result/error."""
    if "text/event-stream" not in ctype:
        return json.loads(body) if body.strip() else {}
    msgs = [json.loads(l[5:].strip()) for l in body.splitlines() if l.startswith("data:") and l[5:].strip()]
    final = [m for m in msgs if "result" in m or "error" in m]
    return final[-1] if final else {}


class Client:
    def __init__(self, token):
        self.token, self.sid, self.n = token, None, 0

    def post(self, payload):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(URL, json.dumps(payload).encode(), h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=400) as r:
                self.sid = r.headers.get("Mcp-Session-Id") or self.sid
                return r.status, parse(r.read().decode(), r.headers.get("Content-Type", ""))
        except urllib.error.HTTPError as e:
            return e.code, {"http_error": e.read().decode()[:300]}

    def rpc(self, method, params=None):
        self.n += 1
        return self.post({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}})

    def init(self):
        st, r = self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                        "clientInfo": {"name": "eis-e2e", "version": "0"}})
        if st == 200:
            self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return st, r

    def call(self, tool, args=None):
        """-> (is_error, data). data = parsed JSON of the first text block when possible."""
        st, r = self.rpc("tools/call", {"name": tool, "arguments": args or {}})
        if st != 200 or "result" not in r:
            return True, r
        res = r["result"]
        if "structuredContent" in res:
            return bool(res.get("isError")), res["structuredContent"]
        text = "".join(c.get("text", "") for c in res.get("content", []))
        try:
            return bool(res.get("isError")), json.loads(text)
        except ValueError:
            return bool(res.get("isError")), text


def selftest():
    sse = 'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress"}\n\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n'
    assert parse(sse, "text/event-stream")["result"] == {"ok": True}
    assert parse('{"id":1,"result":1}', "application/json")["result"] == 1
    assert parse("", "application/json") == {}
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    c = Client(os.environ.get("MCP_TOKEN", ""))
    st, r = c.init()
    if st != 200:
        sys.exit(f"initialize failed: http {st} {r}")
    if sys.argv[1] == "tools":
        flt = sys.argv[2] if len(sys.argv) > 2 else None
        tools = c.rpc("tools/list")[1]["result"]["tools"]
        print("server:", r["result"].get("serverInfo"), "| tools:", len(tools))
        for t in tools:
            if flt is None:
                print(" ", t["name"])
            elif flt in t["name"]:
                props = t.get("inputSchema", {}).get("properties", {})
                print(f'  {t["name"]}  required={t.get("inputSchema", {}).get("required", [])}  args={ {k: v.get("type") for k, v in props.items()} }')
    elif sys.argv[1] == "call":
        err, data = c.call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else {})
        print("isError:", err)
        print(json.dumps(data, indent=1)[:3000] if not isinstance(data, str) else data[:3000])
