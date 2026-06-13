# Cursor Agent CLI Usage - Session Example

## Problem
User wanted to run the Cursor Agent CLI with a specific model, mistakenly using the name "cursor-composer-2-fast", which is not accepted by the CLI.

## Correction & Solution
- The CLI lists valid available models. Prefixes like "cursor-" are not part of the model name.
- Valid choices for Composer models: "composer-2-fast", "composer-2.5-fast", etc.
- Always run:
  ```bash
  agent -p "your prompt here" --model "composer-2-fast"
  ```

## Steps for Agents
1. If model name rejected, enumerate all available models (the CLI usually lists them on error).
2. Suggest the closest match (e.g., "composer-2-fast").
3. Show a fixed agent command in reply for immediate use.
4. Check with user before running high-effort or uncertain tasks.

## Error Example
```
Cannot use this model: cursor-composer-2-fast. Available models: auto, composer-2-fast, composer-2, ...
```

## Lesson
- Proactively suggest and verify model names based on available list.
- Reply concisely with correct examples.
