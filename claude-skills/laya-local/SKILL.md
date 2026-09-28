---
name: laya-local
license: Apache-2.0
description: >
  Build structured decision workflows with Laya running locally. Use Laya as a
  Jev-compatible System One decision engine for choice, score, and noul
  judgments over application state. Prefer local inference when a workflow
  needs routing, classification, scoring, verification, guardrails, triage,
  escalation, or another bounded semantic decision rather than free-form text
  generation. Use this skill when porting TypeSafe/Jev integrations to local
  Laya, designing new Laya workflows, or replacing prompt-and-parse LLM steps
  with typed decisions.
---

# Build with Laya Local

Laya is a local/self-hosted System One decision engine. It takes application
state plus typed questions and returns structured answers with probabilities.
Code owns the workflow; Laya supplies bounded semantic judgment.

This skill is intentionally compatible with the useful design ideas from the
TypeSafe/Jev agent skill while changing the runtime assumption from a hosted
TypeSafe API to local Laya.

## Core rule

Use Laya for **bounded decisions**, not open-ended generation.

Good fits:

- routing
- intent classification
- moderation and guardrails
- ticket/email triage
- relevance checks
- ranking/scoring
- verification
- escalation decisions
- deciding whether a larger model or human should take over

Keep deterministic rules, exact calculations, permissions, side effects, and
execution in normal code.

## Source of truth

Before changing version-sensitive integration code, inspect the current Laya
README, installed package, or API implementation.

Primary references:

- GitHub: https://github.com/NandhaKishorM/laya
- Hugging Face: https://huggingface.co/convaiinnovations/laya
- Local package: inspect the installed `laya` version and types when available.

Do not invent request or response fields. If the runtime API differs from this
skill, follow the installed/runtime contract.

## Local installation

Python 3.10+ is required.

For direct Python use:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install laya
```

For the Jev-compatible HTTP server:

```bash
python -m pip install "laya[serve]"
```

Start locally. `LAYA_HOST` defaults to `0.0.0.0` (all interfaces, no auth) —
always bind to localhost:

```bash
LAYA_HOST=127.0.0.1 LAYA_DEVICE=cpu LAYA_PRELOAD=1 laya-serve
```

Other env vars (laya 0.3.20, see `laya/serve.py` docstring): `LAYA_PORT` (8000),
`LAYA_MODELS` (comma list to preload), `LAYA_THREADS`, `LAYA_AUTO_TASK`,
`LAYA_API_KEY` (requires `Authorization: Bearer`), `LAYA_LOG_LEVEL`.

On Apple Silicon, prefer MPS when supported by the installed PyTorch/Laya build:

```bash
LAYA_DEVICE=mps LAYA_PRELOAD=1 laya-serve
```

For NVIDIA:

```bash
LAYA_DEVICE=cuda LAYA_PRELOAD=1 laya-serve
```

Endpoint (with `LAYA_HOST=127.0.0.1`; add it to the mps/cuda commands too):

```text
POST http://127.0.0.1:8000/v1/systemone
```

For an optional MCP integration:

```bash
python -m pip install "laya[mcp]"
laya-mcp-server
```

MCP tools exposed (0.3.20): `laya_predict`, `laya_route`, `laya_preset`,
`laya_status`. There is no `laya_shortlist` tool despite some docs claiming it.

When MCP is available, prefer the Laya MCP tools for agent workflows instead of
shelling out to curl repeatedly.

## Jev -> Laya migration

Laya's self-hosted HTTP server implements the Jev-compatible
`POST /v1/systemone` protocol.

For an existing Jev client, first try changing only the base URL:

```text
TypeSafe/Jev hosted API
        ↓
http://127.0.0.1:8000
```

Remove the hosted TypeSafe API-key dependency unless you intentionally configure
`LAYA_API_KEY` on your local Laya server.

Do not assume all Jev thresholds transfer unchanged. Laya's `confidence` for
choice/score uses its own definition, and the runtime also exposes
`answer_confidence`. Recalibrate thresholds against your own data.

Before porting a mature Jev flow, diff its request/response fields against the
installed `laya/serve.py` and `laya/common.py`.

## Design the judgments

Laya uses the same three core decision primitives.

| Need | Type | Meaning |
| --- | --- | --- |
| Pick one defined outcome | `choice` | Select one option and return its probability distribution |
| Decide whether a condition holds | `noul` | Return P(true) |
| Measure degree on an ordered rubric | `score` | Return an expected position/level plus distribution |

### Choice

Use `choice` when exactly one of a bounded set should win.

Example:

```json
{
  "type": "choice",
  "instructions": "Which team should handle this incident?",
  "criteria": {
    "platform": "Kubernetes, infrastructure, networking, cluster runtime",
    "application": "Application code or business logic",
    "security": "Credentials, suspicious access, policy or security issue"
  }
}
```

Do not create huge flat choice sets. Laya has a finite option-token budget.
Prefer hierarchical classification or shortlisting when the candidate set grows.

### Noul

Use `noul` for a single yes/no proposition.

Example:

```json
{
  "type": "noul",
  "instructions": "Does this incident require immediate human escalation?"
}
```

Treat the returned value as a probability of the proposition, not as a generic
"confidence" score.

### Score

Use `score` for an ordered dimension.

Example:

```json
{
  "type": "score",
  "instructions": "How urgent is this incident?",
  "criteria": [
    "No operational impact",
    "Degraded but stable",
    "Major production impact"
  ]
}
```

Give every score level a meaningful description.

Response gotcha: the `score` field is the probability-weighted **expected**
level (e.g. `2.05`), not the winning level. Take argmax of `probabilities` for
the most likely level.

## State design

Give Laya only the evidence required for the judgment.

Prefer structured JSON when multiple pieces of context matter:

```json
{
  "cluster": "payments-prod",
  "environment": "production",
  "cpu_utilization": 95,
  "restarting_pods": 7,
  "alert": "Checkout latency above SLO"
}
```

Good state is:

- current
- relevant
- explicit
- small enough for the selected checkpoint
- free of unnecessary secrets

Do not ask the model to infer data that ordinary code can fetch exactly.

## Ask independent questions together

Questions over the same state can be evaluated together.

Example:

```json
{
  "state": {
    "cluster": "payments-prod",
    "event": "7 pods restarting; checkout latency above SLO"
  },
  "questions": {
    "owner": {
      "type": "choice",
      "instructions": "Which team owns this incident?",
      "criteria": {
        "platform": "Cluster/runtime/infrastructure",
        "application": "Application behavior",
        "security": "Security issue"
      }
    },
    "severity": {
      "type": "score",
      "instructions": "How severe is the current production impact?",
      "criteria": [
        "No impact",
        "Minor degradation",
        "Major customer impact"
      ]
    },
    "escalate": {
      "type": "noul",
      "instructions": "Should this incident be escalated to a human immediately?"
    }
  }
}
```

Use a second call only when the first result is required to fetch new evidence or
construct a new candidate set.

## Local HTTP example

```bash
curl -s http://127.0.0.1:8000/v1/systemone \
  -H 'content-type: application/json' \
  -d '{
    "state": {
      "body": "Production checkout pods are restarting and latency is above SLO"
    },
    "questions": {
      "team": {
        "type": "choice",
        "instructions": "Which team should handle this?",
        "criteria": {
          "platform": "Kubernetes or infrastructure",
          "application": "Application code",
          "security": "Security incident"
        }
      },
      "escalate": {
        "type": "noul",
        "instructions": "Does this require immediate human escalation?"
      }
    }
  }'
```

## Direct Python example

```python
from laya import Router

router = Router(preload=True)

state = {
    "body": "Production checkout pods are restarting and latency is above SLO"
}

questions = {
    "team": {
        "type": "choice",
        "instructions": "Which team should handle this?",
        "criteria": {
            "platform": "Kubernetes or infrastructure",
            "application": "Application code",
            "security": "Security incident",
        },
    },
    "escalate": {
        "type": "noul",
        "instructions": "Does this require immediate human escalation?",
    },
}

result = router.predict(state, questions)
print(result["answers"])
```

## Model routing

Prefer Laya's `Router` unless the project has a strong reason to pin a checkpoint.

Available model families include:

- English
- multilingual
- typed-decisions

If a workflow already knows the language or task, pass that information explicitly
when supported instead of making routing harder than necessary.

For a local server, preload the models needed for production traffic to avoid cold
checkpoint reloads.

## Confidence and policy

Typed output guarantees a valid interface. It does **not** guarantee a correct
decision.

Never turn a demo threshold into production policy without measurement.

For automation:

1. collect representative labeled examples;
2. run the exact questions and model configuration used in production;
3. measure error rate and coverage;
4. choose thresholds from the consequences of false positives/negatives;
5. sample automated decisions after deployment;
6. recalibrate after model, prompt/question, checkpoint, or dtype changes.

For `choice`, if the application only needs the most likely option, select the
winner directly. Add a threshold only when uncertainty changes what the workflow
should do.

For `noul`, reason from the probability of the proposition.

Do not blindly reuse Jev `confidence` thresholds in Laya.

## Escalation pattern

Use a layered workflow:

```text
deterministic rules
       ↓
local Laya
       ↓
high-confidence bounded decision ──→ normal code/action
       │
       └─ uncertain / high-impact ──→ reasoning model or human
```

This is often more efficient than sending every routine decision to a generative
LLM.

## Reviewability

Put human-reviewable constants in one place:

- question instructions
- choice criteria
- score rubrics
- thresholds
- model/checkpoint selection
- escalation policy

Suggested structure:

```text
src/
  laya/
    questions.py
    policy.py
    client.py
    evals/
```

Do not bury semantic policy across unrelated application files.

## Evaluation

Create an evaluation set before trusting an automated workflow.

At minimum store:

```text
input state
expected label / acceptable labels
model answer
probabilities
threshold outcome
actual application action
```

Separate:

- missing evidence
- bad question/rubric design
- model error
- threshold/policy error
- integration error
- local server failure

When behavior changes, compare evaluations before and after.

## Long documents

Do not assume a long document fits one model window.

When appropriate, use Laya's long-document support or preselect the evidence in
code. For high-impact workflows, inspect which evidence/span actually drove the
decision.

## Security and privacy

Local inference can keep application state on the local host, but local deployment
does not automatically make a workflow secure.

- bind the server to localhost unless remote access is required;
- set `LAYA_API_KEY` if exposing the HTTP server beyond a trusted local boundary;
- avoid placing secrets in state unless required;
- apply normal application authorization before model execution;
- do not let a model decision bypass deterministic permission checks;
- log enough metadata for audit without unnecessarily logging sensitive payloads.

## Agent behavior when using this skill

When asked to use Laya Local:

1. inspect the project before proposing integration points;
2. find existing Jev/TypeSafe calls, prompt-and-parse classifiers, routers,
   scoring logic, and fragile semantic conditionals;
3. identify which of them are bounded judgments;
4. preserve deterministic code and side effects;
5. centralize questions and thresholds;
6. prefer the Jev-compatible local endpoint for low-friction migrations;
7. use direct SDK/MCP only when it improves the project architecture;
8. create or update tests/evaluations;
9. run a small real experiment when a local Laya server is available;
10. report measured behavior instead of claiming that confidence implies correctness.

## This machine

- venv + install: `~/laya-local/.venv` (laya 0.3.20, `[serve]`).
- Server: `cd ~/laya-local && LAYA_HOST=127.0.0.1 LAYA_DEVICE=cpu .venv/bin/laya-serve`
  → `http://127.0.0.1:8000/v1/systemone`. Check first: `lsof -nP -iTCP:8000 -sTCP:LISTEN`.
- Playground UI: `~/laya-local/.venv/bin/python ~/laya-local/playground.py` →
  `http://127.0.0.1:8080` (proxies `/v1/*`; laya-serve has no CORS). `{{key}}`
  in questions resolves from state client-side.
- Known: checkpoint warns "invalid temperatures ... uncalibrated" on load —
  treat confidence as uncalibrated until measured.
- Device: prefer `LAYA_DEVICE=mps`. Benchmarked 2026-09-26 (`~/laya-local/bench.py`,
  3 questions): mps p50 72ms / p90 88ms vs cpu p50 193ms / p90 399ms; answers
  identical (max |dp| = 0.0000).
- MCP: registered user-scope as `laya` (`claude mcp get laya`), stdio,
  `LAYA_DEVICE=mps LAYA_MODELS=english`. Tools appear as `mcp__laya__laya_predict`
  etc. in new sessions. Add `multilingual` to `LAYA_MODELS` if non-English input.
