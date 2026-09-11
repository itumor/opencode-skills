---
name: harness-ai-evaluator
description: Evaluate, score, benchmark, compare, or audit AI agent harnesses and orchestration platforms using a 100-point Harness AI Evaluation Score. Use when asked to score an AI harness, evaluate agent infrastructure, compare Claude Code, Codex, OpenHands, Devin, LangGraph, CrewAI, Dify, or another agent platform, assess tool orchestration, context engineering, permissions, verification, long-running autonomy, or determine whether a system is a real agent harness versus an LLM wrapper. Evaluate the harness separately from the underlying model and tools/environment.
---

# Harness AI Evaluator

Evaluate the software layer surrounding an LLM rather than judging model intelligence alone.

Use a consistent 100-point framework covering orchestration, context, safety, execution, verification, extensibility, observability, recovery, long-running work, multi-agent support, and cost control.

## Mental model

Separate every evaluated system into these layers:

```text
User task
   │
   ▼
HARNESS
├── Instructions
├── Context
├── Memory
├── Planning
├── Permissions
├── Tool routing
├── Retry logic
├── Verification
└── Logging
   │
   ▼
MODEL
   │
   ▼
TOOLS
   │
   ▼
ENVIRONMENT
```

Do not credit the harness for capabilities that exist only because the underlying model is capable.

Do not penalize the model for deficiencies caused by the harness.

Think in terms of:

```text
Model       = reasoning capability
Harness     = orchestration and control layer
Tools       = external capabilities
Environment = systems where actions occur
```

For Claude-based systems, for example:

```text
Claude model        = Model
Claude Code         = Harness
MCP                  = Tool connection mechanism
kubectl/AWS/GitHub  = Tools
Laptop/CI/K8s       = Environment
CLAUDE.md/Skills    = Instructions and context
```

## Core evaluation rules

1. Score documented or observed behavior, not marketing language.
2. Separate harness features from underlying model capabilities.
3. Prefer current evidence over historical behavior.
4. Do not assume an undocumented capability exists.
5. Do not automatically treat undocumented capability as absent.
6. Mark uncertain findings as low confidence.
7. Explain why every score was assigned.
8. Do not reuse an old vendor score without re-evaluating current evidence.
9. Evaluate the product as deployed for the user's stated use case.
10. For DevOps, infrastructure, security, or production operations, pay particular attention to permissions, blast radius, verification, recovery, and auditability.

A previously reported score such as `91/100` is historical evidence or an example, not a permanent score.

## Evidence hierarchy

Prefer evidence in this order:

```text
1. Direct observation / reproducible test
2. Official technical documentation
3. Source code or authoritative repository
4. API / SDK documentation
5. Architecture documentation
6. Vendor technical demonstrations
7. Independent technical analysis
8. Marketing statements
9. Unverified claims
```

When evidence is incomplete, continue scoring using only what can reasonably be established and explicitly identify uncertainty.

Never invent missing capabilities to make the score complete.

## Step 1 — Define evaluation scope

Identify:

```text
Harness:
Version/date:
Primary use case:
Deployment model:
Available tools:
Underlying model(s):
Environment:
Evidence provided:
```

If the user provides architecture documents, code, configuration, or documentation, evaluate those directly.

If the user asks for a current vendor evaluation and research tools are available, use current authoritative documentation.

## Step 2 — Score the 100-point framework

Use exactly these weights:

| Capability                |  Weight |
| ------------------------- | ------: |
| Tool orchestration        |      15 |
| Context engineering       |      15 |
| Permissions & safety      |      15 |
| Planning / execution loop |      10 |
| Verification              |      10 |
| Extensibility             |      10 |
| Observability             |       5 |
| Recovery / retries        |       5 |
| Long-running tasks        |       5 |
| Multi-agent support       |       5 |
| Cost / token control      |       5 |
| **TOTAL**                 | **100** |

Do not change these weights unless the user explicitly requests a customized framework.

---

# 1. Tool orchestration — 15 points

Evaluate whether the harness gives the model the correct tool at the correct time with appropriate inputs and context.

Look for:

```text
tool discovery
tool descriptions
tool routing
argument generation
tool-result interpretation
tool boundaries
dependency sequencing
parallel tool execution
token-efficient results
dynamic tool selection
```

Scoring anchors:

```text
15  Excellent tool selection, sequencing, routing, and result handling
12  Usually selects and uses tools correctly
8   Tool support exists but routing or sequencing is inconsistent
4   User must manually direct most tool use
0   No meaningful tool execution
```

Do not award full points merely because many integrations exist.

Ask:

> Can the harness reliably decide which tool should be used, when it should be used, and what to do with the result?

---

# 2. Context engineering — 15 points

Evaluate whether the harness supplies the correct information at the correct time without unnecessarily flooding the model context.

Look for:

```text
project instructions
dynamic context retrieval
context filtering
skills
memory
repository awareness
session state
context compaction
structured state
handoff artifacts
context-window management
retrieval quality
```

Scoring anchors:

```text
15  Excellent selective context, retrieval, state, and context management
12  Strong context engineering with minor limitations
8   Useful context mechanisms but substantial manual/static loading
4   Mostly static prompts or large context dumps
0   No meaningful context management
```

The size of the model's context window alone does not earn points.

Evaluate:

```text
what information is supplied
when it is supplied
how much is supplied
how irrelevant context is excluded
```

---

# 3. Permissions & safety — 15 points

Evaluate blast-radius controls around agent actions.

Look for:

```text
tool allowlists
tool denylists
per-tool permissions
command-level permissions
human approval gates
sandboxing
filesystem isolation
network restrictions
secret handling
RBAC
policy enforcement
dangerous-operation controls
auditability
```

Scoring anchors:

```text
15  Strong granular permissions, isolation, policy controls, and approvals
12  Strong permissions with a few missing controls
8   Useful but coarse-grained safety controls
4   Mostly prompt-based safety or broad permissions
0   Unrestricted execution with no meaningful harness controls
```

For infrastructure agents, distinguish actions such as:

```text
READ
kubectl get
kubectl describe
AWS Describe*
metrics queries

CHANGE
edit Terraform
create branch
create pull request

HIGH RISK
kubectl apply
ArgoCD sync
IAM modification
terraform apply
resource deletion
```

A strong harness should make it possible to apply different policies to different risk levels.

---

# 4. Planning / execution loop — 10 points

Evaluate whether the harness supports iterative agent execution.

Look for:

```text
task decomposition
planning
act → observe loops
re-planning
progress tracking
dependency management
state transitions
task queues
completion criteria
```

Scoring anchors:

```text
10  Robust planning, decomposition, execution, observation, and re-planning
8   Strong iterative execution
6   Functional plan/act loop with limitations
3   Mostly linear multi-step execution
0   Essentially single-shot prompting
```

The important pattern is:

```text
Plan
 ↓
Act
 ↓
Observe
 ↓
Update state
 ↓
Re-plan
```

---

# 5. Verification — 10 points

Evaluate whether the harness checks work instead of accepting the model's own claim that a task succeeded.

Look for:

```text
tests
linters
validation
diff inspection
acceptance criteria
policy checks
independent evaluator
review agents
runtime validation
post-action verification
rollback checks
```

Scoring anchors:

```text
10  Comprehensive external or independent verification
8   Strong automated verification
6   Regular tool-based checks and tests
3   Mostly model self-review
0   Agent says "done" without verification
```

Example of strong verification:

```text
change
  ↓
format
  ↓
validate
  ↓
test
  ↓
inspect diff
  ↓
compare with requirement
  ↓
independent review where appropriate
  ↓
complete
```

Do not equate self-reflection with external verification.

---

# 6. Extensibility — 10 points

Evaluate how easily new capabilities can be connected to the harness.

Look for:

```text
MCP
custom tools
plugins
APIs
SDKs
hooks
custom agents
skills
external integrations
tool schemas
extension lifecycle
```

Scoring anchors:

```text
10  Highly modular ecosystem with strong custom-tool integration
8   Strong APIs/MCP/plugin/custom-tool support
6   Extensible but requires substantial engineering
3   Limited predefined integrations
0   Closed fixed capability set
```

Large integration count is less important than whether developers can safely add new capabilities.

---

# 7. Observability — 5 points

Evaluate whether operators can understand what the agent did.

Look for:

```text
execution logs
tool-call history
traces
reason/action timeline
token usage
cost tracking
errors
approval history
audit logs
exportability
replay/debugging
```

Scoring anchors:

```text
5  Detailed traceability, auditability, usage data, and debugging
4  Strong execution traces and tool history
2  Basic logging
0  Agent activity is largely opaque
```

---

# 8. Recovery / retries — 5 points

Evaluate behavior when tools or environments fail.

Test or investigate scenarios such as:

```text
API timeout
HTTP 429
AccessDenied
tool crash
MCP disconnect
repository conflict
Terraform lock
malformed response
partial operation
network failure
```

Scoring anchors:

```text
5  Classifies failures, retries intelligently, finds alternatives, and re-plans
4  Strong recovery and fallback behavior
2  Basic retry support
0  Failure normally terminates the task
```

Excellent recovery resembles:

```text
Failure
   ↓
Classify
   ↓
Retry if transient
   ↓
Choose alternative evidence/tool
   ↓
Re-plan
   ↓
Verify
```

---

# 9. Long-running tasks — 5 points

Evaluate whether the harness can operate reliably over long tasks and multiple execution windows.

Look for:

```text
resume
persistent state
checkpoints
structured progress files
context reset
handoffs
task continuation
session recovery
progress tracking
idempotency
```

Scoring anchors:

```text
5  Strong persistent state and structured continuation
4  Reliable long-running/resumable execution
2  Can execute many steps but state management is weak
0  Primarily short interactive tasks
```

Pay attention to whether the harness repeats completed work after context resets.

---

# 10. Multi-agent support — 5 points

Evaluate meaningful orchestration of specialized agents.

Look for:

```text
planner
worker
reviewer
investigator
tester
evaluator
delegation
parallel agents
agent-specific permissions
agent-specific context
handoffs
coordination
```

Scoring anchors:

```text
5  Strong orchestration of specialized agents with useful coordination
4  Effective delegation and multiple roles
2  Basic subagent support
0  No meaningful multi-agent capability
```

Do not award full points merely because multiple model calls can run concurrently.

---

# 11. Cost / token control — 5 points

Evaluate the harness's ability to control resource consumption.

Look for:

```text
token reporting
cost reporting
budgets
context filtering
context compaction
model routing
model selection
limits
tool-result compression
cache use
per-task accounting
```

Scoring anchors:

```text
5  Strong budgeting, routing, context efficiency, and cost visibility
4  Good controls and usage tracking
2  Basic token/cost reporting
0  Little or no control or visibility
```

---

# Step 3 — Record evidence confidence

For every category, assign:

```text
HIGH
Direct observation, source code, or explicit current technical documentation

MEDIUM
Credible technical evidence but incomplete implementation detail

LOW
Indirect evidence, marketing claims, inference, or substantial unknowns
```

Confidence does not alter the 100-point score.

Instead report an overall evidence-confidence assessment separately.

Example:

```text
Harness Score: 86/100
Evidence Confidence: HIGH

or

Harness Score: 86/100
Evidence Confidence: LOW
```

This prevents unsupported confidence from being hidden behind a precise numerical score.

## Unknown versus absent

Use these distinctions:

```text
SUPPORTED
Evidence shows the capability exists.

PARTIAL
Evidence shows some capability but not the complete behavior.

NOT EVIDENCED
Available information does not establish whether it exists.

ABSENT
Evidence establishes that the capability does not exist.
```

Do not silently convert `NOT EVIDENCED` into `ABSENT`.

When the distinction materially affects the score, explicitly mention it.

# Step 4 — Calculate the score

Add all category scores.

Verify that:

```text
tool orchestration       /15
context engineering      /15
permissions & safety     /15
planning/execution       /10
verification             /10
extensibility            /10
observability             /5
recovery/retries          /5
long-running tasks        /5
multi-agent support        /5
cost/token control        /5
                         ----
TOTAL                    /100
```

Recalculate the sum before presenting the result.

Use integer scores unless the user specifically requests greater precision.

## Interpretation

```text
95–100  Exceptional harness
90–94   Excellent
80–89   Very strong
70–79   Good
60–69   Basic agent harness
<60     Mostly an LLM wrapper
```

Do not allow the textual rating to contradict the numerical range.

# Step 5 — Produce the evaluation

Use this output structure unless the user requests another format.

## Harness AI Evaluation

**Harness:** [name]
**Version/date evaluated:** [version/date or unknown]
**Primary use case:** [use case]
**Harness Score:** **XX/100 — RATING**
**Evidence Confidence:** HIGH / MEDIUM / LOW

| Capability           |  Weight |  Score | Confidence | Assessment          |
| -------------------- | ------: | -----: | ---------- | ------------------- |
| Tool orchestration   |      15 |      X | HIGH       | concise explanation |
| Context engineering  |      15 |      X | HIGH       | concise explanation |
| Permissions & safety |      15 |      X | MEDIUM     | concise explanation |
| Planning / execution |      10 |      X | HIGH       | concise explanation |
| Verification         |      10 |      X | MEDIUM     | concise explanation |
| Extensibility        |      10 |      X | HIGH       | concise explanation |
| Observability        |       5 |      X | MEDIUM     | concise explanation |
| Recovery / retries   |       5 |      X | LOW        | concise explanation |
| Long-running tasks   |       5 |      X | MEDIUM     | concise explanation |
| Multi-agent support  |       5 |      X | HIGH       | concise explanation |
| Cost / token control |       5 |      X | MEDIUM     | concise explanation |
| **TOTAL**            | **100** | **XX** |            |                     |

Then provide:

### Why it scored this way

Explain the 3–5 factors having the largest impact on the result.

### Strongest harness capabilities

Identify the strongest architectural characteristics.

### Weakest harness capabilities

Identify important weaknesses, missing controls, or areas that are not evidenced.

### Model vs. harness

Explicitly identify notable capabilities that belong primarily to:

```text
Model
Harness
Tools
Environment
```

This prevents model quality from artificially inflating the harness score.

### Production / operational risk

When relevant, highlight:

```text
permission gaps
blast-radius concerns
verification gaps
secret exposure
network access
destructive actions
auditability
rollback behavior
human approval requirements
```

### Bottom line

Conclude in 2–4 sentences:

```text
What kind of harness is this?
Where is it strongest?
What prevents it from scoring higher?
Would I trust it for the stated use case?
```

# Comparing multiple harnesses

When the user asks for a comparison, evaluate each product independently before ranking them.

Never decide the winner first and then adjust individual scores.

Produce:

| Harness   | Score | Rating | Evidence confidence | Best capability | Main limitation |
| --------- | ----: | ------ | ------------------- | --------------- | --------------- |
| Harness A |    XX | ...    | ...                 | ...             | ...             |
| Harness B |    XX | ...    | ...                 | ...             | ...             |

Then show the detailed category comparison:

| Capability           |  Weight | Harness A | Harness B |
| -------------------- | ------: | --------: | --------: |
| Tool orchestration   |      15 |         X |         X |
| Context engineering  |      15 |         X |         X |
| Permissions & safety |      15 |         X |         X |
| Planning / execution |      10 |         X |         X |
| Verification         |      10 |         X |         X |
| Extensibility        |      10 |         X |         X |
| Observability        |       5 |         X |         X |
| Recovery / retries   |       5 |         X |         X |
| Long-running tasks   |       5 |         X |         X |
| Multi-agent support  |       5 |         X |         X |
| Cost / token control |       5 |         X |         X |
| **TOTAL**            | **100** |    **XX** |    **XX** |

Explain category differences rather than relying only on the total score.

# DevOps / AIOps evaluation mode

When evaluating a harness that can operate cloud or production infrastructure, inspect these controls especially carefully:

```text
AWS permissions
Kubernetes RBAC
GitOps restrictions
secret access
network access
MCP/tool permissions
human approval
command restrictions
production/environment separation
Terraform permissions
destructive operations
audit trail
rollback strategy
post-change verification
```

Typical workflow quality should be evaluated as:

```text
Investigate
   ↓
Form hypothesis
   ↓
Gather evidence
   ↓
Verify hypothesis
   ↓
Propose change
   ↓
Check policy
   ↓
Human approval where required
   ↓
Execute
   ↓
Verify resulting state
```

A harness capable of destructive operations without adequate controls should lose substantial permissions/safety points even when the underlying model is highly capable.

# Optional full Agentic AI Score

Only use this when the user explicitly asks to evaluate the entire agentic system rather than the harness alone.

Use:

```text
MODEL                30%
HARNESS              45%
TOOLS + ENVIRONMENT  25%
```

Keep the normal Harness AI Evaluation Score as an independent `/100` score first.

Then calculate the overall system score separately.

Example:

```text
Model score:               90 × 0.30
Harness score:             88 × 0.45
Tools/environment score:   85 × 0.25

Overall Agentic AI Score = weighted total
```

Never substitute the Agentic AI Score for the Harness AI Evaluation Score without clearly labeling the difference.

# Vendor evaluation questions

Use these questions when deeper investigation is needed:

| Question                                                 | Priority          |
| -------------------------------------------------------- | ----------------- |
| Can I bring my own model?                                | Medium            |
| Can models be changed per task?                          | Medium            |
| Does it support MCP or equivalent open tool integration? | Critical          |
| Can developers create custom tools?                      | Critical          |
| Does it support subagents?                               | High              |
| Can agents execute concurrently?                         | Medium            |
| Are tool permissions available?                          | Critical          |
| Can permissions be scoped per tool/action?               | Critical          |
| Are human approval gates supported?                      | Critical          |
| Can code execution be sandboxed?                         | Critical          |
| Can network access be constrained?                       | Critical          |
| Can secret access be controlled?                         | Critical          |
| Is a complete execution trace available?                 | Critical          |
| Does it recover from tool/API errors?                    | High              |
| Can tasks run/resume over long periods?                  | High              |
| Is state persistent?                                     | High              |
| Is context compacted or selectively retrieved?           | High              |
| Are reusable skills/instructions supported?              | High              |
| Are evaluations built into the platform?                 | Critical          |
| Is token/cost usage tracked?                             | High              |
| Is an API/SDK available?                                 | Critical          |
| Can it be self-hosted?                                   | Context dependent |
| Is enterprise RBAC available?                            | High              |
| Are audit logs available?                                | Critical          |

Do not mechanically turn this questionnaire into points. Use the evidence to score the appropriate categories.

# Important anti-patterns

Avoid these evaluation mistakes:

```text
Many integrations = excellent orchestration
Large context window = excellent context engineering
Smart model = strong harness
Self-review = independent verification
Multiple model calls = sophisticated multi-agent architecture
Retries = intelligent recovery
Long session = persistent state
Prompt asking for permission = real permission enforcement
Marketing saying "secure" = strong safety score
Vendor claims = verified behavior
```

Require architectural evidence wherever possible.

# Final quality check

Before answering, verify:

* All 11 weighted categories were considered.
* Category scores sum to exactly 100 possible points.
* Actual scores were added correctly.
* Model capabilities were not incorrectly credited to the harness.
* Unknown capabilities were not described as confirmed.
* Confidence reflects evidence quality.
* Current products were not scored solely from historical capabilities.
* Production risks are highlighted when the harness can modify real systems.
* The final rating matches the numerical score.
* Any comparison uses the same rubric for every harness.
