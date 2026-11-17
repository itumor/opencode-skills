---
name: conclusion-first-updates
description: Use when preparing something Ebrahim will say or present to people - standup or team-meeting update, 1:1 with his lead, solution or design presentation, demo intro, "what do I say about X", "summarize this for the meeting", "60-second summary", "elevator pitch", "prepare me for the call" - and when a Jira status update or ticket comment is growing past 5 bullets or filling up with technical detail nobody asked for.
---

# Conclusion-first updates

The listener wants four things: what was done, the outcome, what blocks, what is next.
Everything else waits until someone asks. Root-cause mechanics, tool names, MR numbers and
the investigation story are backup, not the update.

Voice for anything written: skill `eramadan-voice`. Jira comment mechanics: skill `jira-draft`.

## Jira status update: 3 to 5 bullets

```text
<greeting> [~user] , <one sentence: the outcome>
 * Done: <what changed, in the reader's terms>
 * Outcome: <verified result, who confirmed, when>
 * Blocker: <what, owner, ticket>            (drop the bullet if none)
 * Next: <action, owner, date>
<one link for detail: MR or page>
```
One line per bullet. Root cause = one clause inside `Done`, only if the reader needs it.

## Meeting or standup update: 3 sentences, about 20 seconds

```text
1. Conclusion: <state now: fixed / blocked / on track / need a decision>
2. One fact that proves it: <number, date, or who verified>
3. Next or ask: <what happens next, or what I need from this room>
```
Then stop talking. Detail comes out only when asked.

## 60-second solution summary: 130 words max

```text
Problem:  <who is hurt and what it costs, 1-2 sentences, no tool names>
Solution: <what we do, not how, 1-2 sentences>
Impact:   <one number: time saved, cost, risk removed, things deleted>
Ask:      <the decision or resource needed, and by when>
```

## Backup (every format)

Under the text, add `If asked:` with up to 5 one-line facts (root cause, MR links, cost
detail, alternatives, rollback). He keeps these in his pocket; they are not read out.

## Output

1. The text in one fenced block, ready to paste or say.
2. Word count for spoken text.
3. `If asked:` list.

## Check before output

- First sentence is the conclusion, not background.
- Jira: 5 bullets or fewer. Standup: 3 sentences. Summary: 130 words or fewer.
- Every acronym and tool name is one the audience uses; otherwise say what it does.
- Impact has a number.
- Each next step has an owner. Give a date only for work he controls.
- Anything not verified is `<TODO>`, never invented.
