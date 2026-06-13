User timezone: +03:00 (CEST/CET), based on cron job schedules
Uses LM Studio for local LLM inference (had GGUF runtime issues)
Prefers concise, bullet-point responses
Migrated all 8 cron jobs from GPT-5.4-mini (openai-codex) to minimax-m2.5-free (opencode-zen)
Config fixes needed: terminal.cwd → /Users/eramadan/.hermes, max_tokens → 16000, tool_output.max_bytes → 150000
Current config lives at /Users/eramadan/.hermes/config.yaml
§
Preferred model: minimax-m2.5-free via opencode-zen (primary); Ollama qwen2.5-coder:32b as local fallback at http://localhost:11434. Ollama config: provider=ollama-local, base_url=http://localhost:11434/v1, fallback_providers=[ollama-local]. Config tuned: max_tokens=16000, tool_output.max_bytes=150000. prefers concise responses on Telegram.
§
Cursor CLI: To run with Composer 2 Fast, use agent -p "<prompt>" --model "composer-2-fast" --trust. User prefers Cursor commands to explicitly specify the model and use the --trust flag for workspaces.
§
OpenAI Codex with this ChatGPT account rejects gpt-4.5-mini for cron jobs; the last known working Codex cron model was gpt-5.4-mini.