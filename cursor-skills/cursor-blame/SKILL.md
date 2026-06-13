---
name: cursor-blame
description: >-
  Investigate how code was built with AI. Reveals which conversations produced
  the code, why it was implemented a certain way, what alternatives were
  considered, and the intent behind decisions. Use when the user asks about
  history, evolution, or authorship of code.
disable-model-invocation: true
---
# Cursor Blame

This skill helps you investigate the history and intent behind code changes made with AI assistance.

## When to Use

- When asking about why code was written a certain way
- When investigating the history of a file or function
- When understanding what alternatives were considered
- When tracing the evolution of a codebase

## How It Works

Cursor Blame correlates code with the AI conversations that produced it, providing:
- Conversation context and summaries
- Decision rationale and tradeoffs discussed
- Models used during development
- Timeline of changes

## Usage

Simply ask questions like:
- "Why was this function implemented this way?"
- "What was the reasoning behind this architecture decision?"
- "Show me the history of changes to this file"
