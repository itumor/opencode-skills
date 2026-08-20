---
name: architecture-diagram-review
description: Sanity-check an architecture/network diagram (Lucidchart, draw.io, Confluence image, PNG) against the real IaC and live cloud state, then deliver the findings — as a paste-ready comment, as anchored comments on the diagram itself, or both. Use when asked to "sanity check this diagram", "review this architecture", "is this diagram accurate", "check my network diagram", when someone shares a Lucid/draw.io link asking for a look, or when a diagram is about to become the reference doc for an audit, onboarding, or customer hand-off. Encodes the read-the-diagram-first rule, the finder dimensions, the live-verification battery, the dedup/adversarial-verify pass, and the Lucid commenting mechanics that silently corrupt shapes if done wrong.
---

# Architecture diagram review

## The rule

**A diagram finding is only a finding if you can name the file:line or the CLI output that contradicts it.** Never review a diagram against your memory of the estate — the whole value is that the diagram and reality have drifted, and you don't know which way.

Second rule: **transcribe the diagram completely before you check anything.** Every finding is "diagram says X, reality is Y" — if X is your paraphrase you will produce findings that don't survive contact with the actual picture.

## Step 1 — Establish scope, before anything else

Ask (or infer and state) what the diagram is *for*. This single answer decides whether half your findings are findings at all:

- **One client / one environment?** Then a shared hub showing only that client's route tables is *correct*, not an omission. Don't ask for other tenants. Keep multi-tenancy only as change-blast-radius context.
- **Whole estate?** Then missing regions/tenants/accounts are real gaps.
- **Current state or target state?** Future-state boxes drawn solid is the single most common real defect — but only a defect if the diagram claims to be current.

Getting this wrong late is expensive: re-scoping means editing already-posted comments. Ask up front.

## Step 2 — Transcribe the diagram

Open it read-only, fit to content, and zoom region by region. Write out, in a scratch file:
- every container and its label (accounts, VPCs, regions, subnets) — including CIDRs and account IDs shown
- every node and its label, and **the exact text** of every hostname/name/CIDR chip
- every connector, its direction, and whether it is solid or dashed
- explicitly, a **NOT DRAWN** list — this is what makes the "missing component" findings possible

Zoom in far enough to read small text. Placeholder values (repeated CIDRs, `<Production Domain>`, template defaults) hide at low zoom and are high-value findings.

## Step 3 — Fan out finders over the code

Dimensions that each earn their own pass (adapt to the stack):

| Finder | Looks for |
|---|---|
| shared/hub repo | route tables, associations vs propagations, peering enabled/disabled, egress + inspection topology, resolver, RAM shares |
| per-env core | VPC/subnet/AZ layout, routing, VPN, DNS zones + delegation, prefix lists |
| per-env services | load balancers (scheme! target type!), compute inventory, data plane, endpoints |
| architecture docs | the repo's own ADRs/docs — where the diagram contradicts them, the docs usually win |
| cross-repo | GitOps/ingress configs, Ansible host inventories, module defaults that change what an icon means |
| git history | which drawn things landed only on an unmerged branch, which were **removed**, and the owning ticket per finding |
| live cloud | the truth (Step 4) |

Feed every finder the full diagram transcription **and** a de-dup list of findings already known, or you get the same finding six times. Cap findings per finder and verify each adversarially — instruct verifiers to refute, defaulting to refuted. Expect ~20-25% survival; that is the pass working, not failing.

Then **run the same skeptical pass over your own conclusions.** See `feedback_prove-absence-before-asserting` — an "X is unmanaged" claim of mine was wrong because a sibling stage's `*_custom.tf` owned it.

## Step 4 — Verify live (this is what makes the review credible)

Code tells you intent; only the API tells you what exists. Enumerate profiles first — a missing profile is not proof of no access, and it *is* a gap worth reporting.

```bash
aws sts get-caller-identity --profile <p>
# names + topology
aws ec2 describe-transit-gateways --profile <p> --region <r> \
  --query 'TransitGateways[?State!=`deleted`].[TransitGatewayId,Tags[?Key==`Name`]|[0].Value,Options.AmazonSideAsn]' --output text
aws ec2 describe-transit-gateway-route-tables --profile <p> --region <r> \
  --query 'TransitGatewayRouteTables[?State==`available`].[Tags[?Key==`Name`]|[0].Value]' --output text
aws ec2 describe-transit-gateway-peering-attachments --profile <p> --region <r> \
  --query 'TransitGatewayPeeringAttachments[].[TransitGatewayAttachmentId,State,AccepterTgwInfo.Region,RequesterTgwInfo.Region]' --output text
# VPN health — tunnel state is invisible in code
aws ec2 describe-vpn-connections --profile <p> --region <r> \
  --query 'VpnConnections[?State!=`deleted`].[Tags[?Key==`Name`]|[0].Value,State,VgwTelemetry[].Status,VgwTelemetry[].OutsideIpAddress]'
# scheme is the finding: internal vs internet-facing, and AZ count
aws elbv2 describe-load-balancers --profile <p> --region <r> \
  --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,AvailabilityZones[0].ZoneName,length(AvailabilityZones)]' --output text
aws ec2 describe-vpcs --profile <p> --region <r> --query 'Vpcs[].[CidrBlock,Tags[?Key==`Name`]|[0].Value,IsDefault]' --output text
aws route53 list-hosted-zones --profile <p> --query 'HostedZones[].[Name,Config.PrivateZone,Id]' --output text
aws transfer list-connectors --profile <p> --region <r>   # then describe-connector: EgressType
```

**Resolve every security-group prefix list to its CIDRs** — `describe-security-groups` showing a `PrefixListIds` entry tells you nothing. `aws ec2 get-managed-prefix-list-entries` is where `0.0.0.0/0` hides behind a friendly name like `<env>-all`. This is how a drawn "restricted NLB → ALB" chain turns out not to be a chokepoint.

Shell note: a tab-separated `--output text` list of IDs does not word-split into `--group-ids` under zsh. Query one at a time or `tr '\t' ' '` and pass via `$(...)` carefully.

## Step 5 — Findings that recur across every diagram

Check these explicitly; they are almost always present:

1. **Future state drawn solid.** Grep for the stack: no directory, or a services dir with none of the expected `.tf` files, means it doesn't exist. Check whether it lives only on an unmerged branch.
2. **Object names are invented.** Diagram names are rarely the AWS `Name` tag. Compare every label.
3. **Region/env code slips.** Where a naming module maps region→code, one wrong code propagates through every label in that region. Read the map, don't guess.
4. **Placeholder CIDRs/domains** copied from a template and never replaced.
5. **Load balancers drawn ambiguously.** "Static IP" reads as public; check `Scheme`, AZ pinning, and whether there are *more* of them than drawn.
6. **Egress paths that skip the drawn egress** — service-managed SFTP/Transfer, VPC Lattice, gateway/interface endpoints, undeleted default VPCs with an IGW. See `sftp-service-managed-egress-bypass`.
7. **A link that is disabled in code but drawn live** (peering `enabled = false`, a provisioning-only flag marked "flip at cut-off"). Draw dashed or delete.
8. **Cross-account dependencies with no line** — a DNS apex or delegation owned by a different account, an external control-plane account holding cluster-admin.
9. **Compute in the "wrong" box** because it was deliberately re-homed; `git log` gives you the ticket and the reason, which makes the comment persuasive.
10. **Secondary/pod CIDRs outside the box's own CIDR label.**

## Step 6 — Deliver

Two products; ask which, or do both:

**A paste-ready comment.** Lead with what is *correct* — specifically, naming a non-obvious thing they got right buys the credibility to spend on 13 corrections. Then findings worst-first, each as "what the diagram says / what is true / the evidence / the proposed fix". Close with "if you change only two things: …". End with the verification caveat (what was live-checked vs code-only). Write it to a file and send it as well as printing it.

**Anchored comments on the diagram.** Only ever on a **copy** the requester provides or after explicit permission — comments notify collaborators and are outward-facing. One comment per shape, each self-contained (`FIX -` / `MISSING -` / `DETAIL -` + evidence + `PROPOSAL:`), because readers see them one at a time. Mechanics and the two ways to silently corrupt shapes: **`lucid-comment-automation`** — read it before the first comment, not after.

## Anti-patterns

- Reviewing from memory of the estate.
- Reporting icon-census nits ("8 icons, 11 hosts") as errors — a stylised group asserts nothing. Name the hosts as an *improvement* instead.
- Asserting absence without a repo-wide positive search.
- Blind-clicking a floating context menu in the diagram tool.
- Editing the original diagram instead of a copy.
