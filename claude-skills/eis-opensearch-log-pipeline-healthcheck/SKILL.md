---
name: eis-opensearch-log-pipeline-healthcheck
description: >-
  Prove a Filebeat -> Logstash -> AWS OpenSearch log pipeline is healthy, and diagnose its
  index failures, with read-only API calls and Dashboards screenshots. No kubectl needed. Use
  when asked "make sure logs work 100%", "prove the 400 is fixed", "are logs from pod X in
  OpenSearch", "Logstash Could not index event status 400", "mapper_parsing_exception object
  mapping for [X]", "Limit of total fields exceeded", or "show proof in OpenSearch Dashboards".
  Covers domain health, freshness per index family, Logstash/Filebeat error scans, node coverage
  vs EKS, prediction of future mapping clashes, and Dashboards proof (Discover + Dev Tools).
---

# Log pipeline health check (Filebeat -> Logstash -> OpenSearch)

Reference run: CAA `aws11caashareos01`, 2026-11-03 (COEXT-109331). Memories:
[[caa-share-opensearch-readonly-e2e]] (SigV4 helper, auth),
[[opensearch-filebeat-metrics-total-fields-limit]],
[[opensearch-logstash-root-key-type-clash]], and
[[feedback-proof-query-zero-before-fix]].

All calls are signed GETs, or POST `_search`, through the master-role SigV4 helper. Never put `*` or `,`
in the URL path, because SigV4 breaks: use `_all/_search` with a `prefix` filter on `_index`,
and URL-encode wildcards as `%2A` in query strings. Put multi-step checks in a script file
(harness R15 fires on inline heredocs).

## 1. Domain
`_cluster/health` (green, unassigned 0) · `_cat/thread_pool/write?h=node_name,active,queue,rejected`
(rejected 0) · `_cat/allocation?h=node,disk.percent,disk.avail`.

## 2. Freshness per index family
For each `<env>-<cluster>-{infrastructure,<ns>-application,<ns>-dependency}-<today>`: max
`@timestamp`, plus doc counts for the last 15 and 60 minutes. An empty application index is not proof
of failure: compare with yesterday and with the per-container breakdown (Spring apps log
heavily at startup, then go quiet).

## 3. Logstash and Filebeat errors (the 400 proof)
Logstash's own stdout is shipped into the infrastructure index, with one WARN per rejected event:
- Count `kubernetes.pod.name.keyword:logstash-0` AND `match_phrase message:"Could not index
  event"`, with a date_histogram. A drop to 0 after the fix is the proof, and it must be >0 before.
- Pull up to 3000 messages and group by the regex `"reason" => "(.*?)"` plus the target index
  family, so you know every cause, not only the one that was reported.
- Scan logstash-0 and `filebeat-*` pods for WARN/ERROR since the fix. `SIGTERM`, `connection
  refused` or `reset by peer` clustered within ~2 minutes means a redeploy (look for a new
  `kubernetes.pod.uid`, then `Pipeline started`). Filebeat retries, so nothing is lost.

## 4. Coverage
Running nodes: `aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=<c>
Name=instance-state-name,Values=running --query 'Reservations[].Instances[].PrivateDnsName'`.
Compare with the terms of `kubernetes.node.name.keyword` over the last 15 minutes (with `prefix` on `_index`) and with the
cardinality of `agent.name.keyword`. List the namespaces too.

## 5. Predict the next 400s
- Field count per index vs the 1000 limit.
- Object-vs-concrete clashes across days: fetch `<index>/_mapping` for every index into a dir,
  then run `python3 -I ~/.claude/scripts/os-mapping-clash.py <dir>` (it has `--selftest`).
- Fix choice: template `{"type":"object","enabled":false}` accepts both shapes, but makes the field
  unsearchable, so never use it on `host`/`service`. The producer-side fix is a Logstash json `target`.
  `PUT <idx>/_mapping` cannot retype a field that is already mapped, so it waits for the rollover.
- Test any template change on a throwaway `<env>-<cluster>-e2etest-*` index (which gets the real
  template and pipeline): index both shapes, search, then DELETE it.
  `_index_template/_simulate_index/<tomorrow's name>` shows what the next index will get.

## 6. Dashboards proof (user signs in; Claude never enters credentials)
- Discover link on the CyberArk gateway host with `?security_tenant=global`, and set
  `columns:!(kubernetes.namespace,kubernetes.pod.name,...)`. With the default `_source` column, the
  multi-KB Logstash failure messages freeze the renderer (screenshot CDP timeout).
- Env without an index pattern: use Dev Tools. Set the request in the console editor with
  `document.querySelector('.ace_editor').env.editor.setValue(text,-1)` (typing triggers auto-close
  brackets), then click the play icon. Prefer aggregation queries (`size:0`) so the result fits one
  screenshot.
- Creating index patterns writes shared saved objects: the classifier blocks it until the user
  asks for it explicitly. Store the field list afterwards (skill `eis-opensearch-cyberark-saml`).
- Browser times are in the viewer's timezone (EET); put UTC in the drafts.

## Hand-back
Table per env (domain, freshness, nodes, failures since fix, warn scan), what is NOT proven
(e.g. a template fix that is active only from the next daily index), the open producer-side items, and
a caveman Slack draft that cites the screenshots by number. The user sends it.
