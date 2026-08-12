#!/usr/bin/env python3
"""Logging + provider-pinning proxy for Sashiko's openai-compatible provider.

Sits on 127.0.0.1 between Sashiko and an upstream OpenAI-compatible endpoint.
Sashiko needs no changes -- only its base_url points here instead of upstream.

WHY THIS EXISTS
---------------
1. Sashiko logs almost nothing per turn. At --debug it emits only
   "Sending OpenAI request..." and "response received. Tokens: in=N, out=M".
   No tool name, no arguments, no tool result, no assistant reasoning. So a
   191-turn run is completely opaque: you cannot tell thorough investigation
   from the same grep repeated 191 times, and a failed run tells you nothing
   about what the model was actually doing.

2. OpenRouter load-balances by price INVERSELY SQUARED, not cheapest-first,
   so the advertised price is not what you pay. One run was billed $3.33
   against a $0.42 list price -- an 8x surprise discovered only afterwards.
   Sashiko builds its own request body and cannot add OpenRouter's `provider`
   routing field, but a proxy can inject it.

3. When a run fails, the request/response that failed is gone. Three rejected
   report-generation attempts were lost this way, taking the findings with
   them.

WHAT IT RECORDS  (all under --log-dir)
  turns.jsonl    one JSON record per request: model, provider actually used,
                 tokens, cost, tool calls with arguments, finish reason
  activity.log   human-readable running commentary -- what tool ran, with what
                 arguments, and what came back
  replies/       every assistant text reply, in full. Sashiko's stage validator
                 rejects malformed answers that arrived as a clean HTTP 200, so
                 status code alone does not identify the turns that matter.
  bodies/        full request+response JSON for any non-200 or any response
                 that fails to parse, so failures are debuggable after the fact

USAGE
  ./logging-proxy.py --port 8090 --upstream https://openrouter.ai/api/v1 \
      --log-dir ../sashiko/.claude/runs/proxy-<tag> --provider SiliconFlow
  then point Sashiko's base_url at http://127.0.0.1:8090/v1
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
SEQ = 0


def log_activity(msg: str) -> None:
    line = f"{time.strftime('%H:%M:%S')}  {msg}"
    print(line, flush=True)
    with open(os.path.join(ARGS.log_dir, "activity.log"), "a") as fh:
        fh.write(line + "\n")


def summarize_request(body: dict) -> str:
    """One line describing what this turn is asking for."""
    msgs = body.get("messages") or []
    n_tools = len(body.get("tools") or [])
    # The most recent tool result tells us what the model just learned.
    last_tool_result = None
    for m in reversed(msgs):
        if m.get("role") == "tool":
            c = m.get("content") or ""
            last_tool_result = (c[:120] + "…") if len(c) > 120 else c
            break
    parts = [f"{len(msgs)} msgs", f"{n_tools} tools offered"]
    if last_tool_result:
        parts.append(f"prev tool result: {last_tool_result!r}")
    return " | ".join(parts)


def summarize_response(payload: dict) -> tuple[str, list]:
    """Human line + structured tool-call list for the model's reply."""
    choices = payload.get("choices") or []
    if not choices:
        return "(no choices)", []
    msg = choices[0].get("message") or {}
    finish = choices[0].get("finish_reason")
    calls = []
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        name = fn.get("name")
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {"__unparseable__": (fn.get("arguments") or "")[:200]}
        calls.append({"name": name, "arguments": args})

    if calls:
        rendered = "; ".join(
            f"{c['name']}({', '.join(f'{k}={v!r}' for k, v in list(c['arguments'].items())[:3])})"
            for c in calls
        )
        return f"TOOL CALL  {rendered}  [finish={finish}]", calls

    text = (msg.get("content") or msg.get("reasoning_content") or "").strip()
    preview = (text[:200] + "…") if len(text) > 200 else text
    return f"TEXT ({len(text)} chars) [finish={finish}]  {preview!r}", []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence the default stderr spam
        pass

    def _relay(self, method: str) -> None:
        global SEQ
        SEQ += 1
        seq = SEQ

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        body = None
        if raw:
            try:
                body = json.loads(raw)
            except json.JSONDecodeError:
                body = None

        # Provider pinning. OpenRouter defaults to price-weighted load
        # balancing, so without this the same model can be served by a
        # provider several times dearer than the advertised rate.
        if body is not None and "openrouter" in ARGS.upstream:
            if ARGS.provider:
                # Name one endpoint and forbid fallback. Cheapest-first is not
                # the same as working: Novita is joint-cheapest for
                # qwen3-coder-30b and returns {"content":null,"reasoning":null}
                # while billing 1176 completion tokens on tool-heavy turns, so
                # every review fails. Correctness pins the provider; price only
                # chooses among the ones that work.
                # Comma-separated = ordered preference WITH fallback. Pinning a
                # single endpoint is fragile: Google threw 17 rate-limit 429s in
                # one run (60s pause each) and a session dies after 5 transient
                # errors. A fallback list keeps the cheap endpoint first and
                # survives its throttling. A single name still pins hard.
                order = [p.strip() for p in ARGS.provider.split(",") if p.strip()]
                body["provider"] = {"order": order,
                                    "allow_fallbacks": len(order) > 1}
            if ARGS.no_reasoning:
                # glm-4.5-air spends 18k-26k REASONING tokens per turn, and
                # max_tokens caps reasoning + answer together, so the model
                # thinks itself out of room and the answer is truncated
                # (finish=length). Measured: 270,744 reasoning tokens against
                # 211,548 completion tokens in one partial review -- all paid
                # for, all discarded. Turning it off is a different model
                # configuration, not merely a cheaper one; compare quality.
                body["reasoning"] = {"enabled": False}
                raw = json.dumps(body).encode()
                raw = json.dumps(body).encode()
            elif ARGS.sort_price:
                body.setdefault("provider", {"sort": "price"})
                raw = json.dumps(body).encode()

        path = self.path
        # Sashiko is configured with base_url ".../v1"; strip our own prefix so
        # the upstream path is not doubled.
        if path.startswith("/v1"):
            path = path[3:]
        url = ARGS.upstream.rstrip("/") + path

        if body is not None:
            log_activity(f"#{seq:<4} -> {body.get('model','?')}  {summarize_request(body)}")

        headers = {"Content-Type": "application/json"}
        for h in ("Authorization", "HTTP-Referer", "X-Title"):
            if self.headers.get(h):
                headers[h] = self.headers[h]

        started = time.time()
        try:
            req = urllib.request.Request(url, data=raw or None, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=ARGS.timeout) as resp:
                status = resp.status
                out = resp.read()
                # urlopen can return a SHORT read if the connection drops
                # mid-body, without raising. Forwarding that produced
                # "EOF while parsing" in the client and killed a run at 6/11
                # stages. Compare against the declared length and treat a short
                # body as a failure rather than passing it on.
                declared = resp.headers.get("Content-Length")
                if declared is not None and out is not None:
                    try:
                        if len(out) < int(declared):
                            raise IOError(
                                f"short read from upstream: {len(out)} of {declared} bytes"
                            )
                    except ValueError:
                        pass
        except urllib.error.HTTPError as exc:
            status = exc.code
            out = exc.read()
        except Exception as exc:  # network-level failure
            status = 502
            # Shape the failure like a chat completion. Sashiko deserialises
            # into a struct with a required `choices` field, so a bare
            # {"error": ...} produced "Parse error: missing field `choices`"
            # and masked the real cause (an upstream read timeout).
            out = json.dumps({
                "error": {"message": f"proxy upstream error: {exc}"},
                "choices": [{"index": 0, "finish_reason": "error",
                             "message": {"role": "assistant",
                                         "content": f"proxy upstream error: {exc}"}}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            }).encode()

        elapsed = time.time() - started

        payload = None
        try:
            payload = json.loads(out)
        except Exception:
            pass

        # A 200 whose body the client cannot use is worse than an error: Sashiko
        # reports a parse failure that names neither the cause nor the turn.
        # Two runs died this way, at 4/11 and 6/11 stages, from two different
        # shapes: a 200 carrying an error object with no `choices`, and a 200
        # whose body was truncated mid-JSON ("EOF while parsing"). Treat BOTH as
        # upstream failures and hand back something actionable.
        if status == 200 and payload is None:
            snippet = out[-200:].decode("utf-8", "replace") if out else "(empty)"
            log_activity(f"#{seq:<4} !! 200 with unparseable body ({len(out)} bytes), reshaping")
            payload = {
                "error": {"message": f"upstream returned 200 with an unparseable body ({len(out)} bytes)"},
                "choices": [{"index": 0, "finish_reason": "error",
                             "message": {"role": "assistant",
                                         "content": "upstream returned a truncated or malformed body"}}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            }
            out = json.dumps(payload).encode()
            d = os.path.join(ARGS.log_dir, "bodies")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, f"{seq:05d}-200-unparseable.txt"), "w") as fh:
                fh.write(f"tail of body:\n{snippet}")

        if payload is not None and status == 200 and "choices" not in payload:
            detail = payload.get("error")
            detail = (detail.get("message") if isinstance(detail, dict) else detail) or str(payload)[:300]
            log_activity(f"#{seq:<4} !! 200 without choices, reshaping: {str(detail)[:120]}")
            payload = {
                "error": {"message": f"upstream returned 200 without choices: {detail}"},
                "choices": [{"index": 0, "finish_reason": "error",
                             "message": {"role": "assistant",
                                         "content": f"upstream error: {detail}"}}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            }
            out = json.dumps(payload).encode()
            d = os.path.join(ARGS.log_dir, "bodies")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, f"{seq:05d}-200-no-choices.json"), "w") as fh:
                fh.write(str(detail))

        if payload and status == 200:
            line, calls = summarize_response(payload)
            usage = payload.get("usage") or {}
            provider = payload.get("provider") or "?"
            log_activity(
                f"#{seq:<4} <- {status} {elapsed:5.1f}s  provider={provider}  "
                f"in={usage.get('prompt_tokens','?')} out={usage.get('completion_tokens','?')}"
            )
            log_activity(f"       {line}")
            rec = {
                "seq": seq,
                "t": time.time(),
                "elapsed_s": round(elapsed, 2),
                "model": (body or {}).get("model"),
                "provider": provider,
                "status": status,
                "usage": usage,
                "cost": (usage.get("cost") if isinstance(usage, dict) else None),
                "finish_reason": (payload.get("choices") or [{}])[0].get("finish_reason"),
                "tool_calls": calls,
                "n_messages": len((body or {}).get("messages") or []),
            }
            with open(os.path.join(ARGS.log_dir, "turns.jsonl"), "a") as fh:
                fh.write(json.dumps(rec) + "\n")
            # A rejected stage answer comes back as a clean HTTP 200 -- the
            # validator that refuses it is Sashiko's, not the provider's. So
            # status alone never marks the interesting turns. Keep every
            # assistant text reply in full: they are small (a few KB), and one
            # of them is the answer that lost a $3.33 run.
            if not calls:
                # Save the WHOLE message object, not just the fields we expect.
                # A provider that bills completion tokens while `content` and
                # `reasoning_content` are both empty is putting the text
                # somewhere else, and guessing field names loses the evidence.
                d = os.path.join(ARGS.log_dir, "replies")
                os.makedirs(d, exist_ok=True)
                msg = (payload.get("choices") or [{}])[0].get("message") or {}
                with open(os.path.join(d, f"{seq:05d}.json"), "w") as fh:
                    json.dump({"message": msg, "usage": usage,
                               "finish_reason": (payload.get("choices") or [{}])[0].get("finish_reason")},
                              fh, indent=1)
        else:
            # Anything not a clean 200 gets its full bodies kept -- these are
            # exactly the turns that vanish today and take the findings along.
            log_activity(f"#{seq:<4} <- {status} {elapsed:5.1f}s  FAILED, bodies saved")
            d = os.path.join(ARGS.log_dir, "bodies")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, f"{seq:05d}-request.json"), "wb") as fh:
                fh.write(raw or b"{}")
            with open(os.path.join(d, f"{seq:05d}-response.json"), "wb") as fh:
                fh.write(out)

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        self._relay("POST")

    def do_GET(self):
        self._relay("GET")


def main() -> None:
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--upstream", default="https://openrouter.ai/api/v1")
    ap.add_argument("--log-dir", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--sort-price", action="store_true",
                    help="inject OpenRouter provider routing to force the cheapest provider")
    ap.add_argument("--no-reasoning", action="store_true",
                    help="ask OpenRouter to disable extended thinking "
                         "(reasoning tokens can exceed the answer budget)")
    ap.add_argument("--provider", default=None,
                    help="pin one named OpenRouter provider, no fallback "
                         "(overrides --sort-price; use when the cheapest one is broken)")
    ARGS = ap.parse_args()

    os.makedirs(ARGS.log_dir, exist_ok=True)
    log_activity(f"proxy up on 127.0.0.1:{ARGS.port} -> {ARGS.upstream}"
                 f"{'  [provider sort=price]' if ARGS.sort_price else ''}")
    log_activity(f"logging to {ARGS.log_dir}")
    ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
