---
name: "tts-voiceover-script"
description: "Use when writing a voice-over script for a TTS tool (ElevenLabs, Google AI Studio / Gemini TTS) for an explainer or demo video, with a voice description, expression tags and visual cues kept separate."
---

# TTS voice-over script

This is the format used for the Agent Harness explainer ("A Brain Needs a Harness"). That audience was engineers and managers aged 30 to 50, watching on a big event screen, in American English.

## Deliver two files

1. **An annotated script (.md)** with:
   - A header: title, target TTS tool, audience, language, target length, and number of scenes and speech blocks.
   - How to use it in the specific tool: speaker or voice choice, where each field goes, which lines not to paste.
   - A voice description paragraph, plus a short version for character-limited fields.
   - Scenes, each with an approximate time range. Under each scene, a **VISUAL** line (for the animation pass only, never pasted into TTS) and the spoken lines with expression tags.
2. **A copy-paste version (.txt)**: the voice description, then `===== SCENE N =====` blocks with one line per speech block and nothing else.

## Length and pacing

- Plan on about 150 to 160 spoken words per minute: 560 words is about 3.5 minutes. TTS with pauses runs long. A script planned at about 4 minutes came back from ElevenLabs at 4:21.
- Use short sentences, with one idea per sentence. Use ellipses (...) for natural pauses.
- Spell numbers and acronyms the way they should be spoken: "Sixty-five git repos", "Ten E-K-S clusters", "two hundred and sixty-five lessons", "Argo C-D" if the voice stumbles.
- Slow down on numbers and punchlines. Use a quieter, serious tone for failures and a steady, assured close.

## Voice description template

> A confident, warm American [man/woman] in [their] late thirties with a smooth, middle-pitched voice and a neutral General American accent. Sounds like a senior platform engineer who has lived through real production incidents and is explaining them to peers, not selling anything. Calm, unhurried and conversational, with dry, understated humor. Slows down slightly on numbers and key lines, drops to a quieter, serious tone when talking about failures, and finishes with steady, assured authority. Clear diction for a large auditorium.

## Tag formats by tool

- **Google AI Studio (Gemini Flash TTS):** one speech block per line. Put the delivery direction in the block's Expression field (for example `curious, slow`). In the text, use `<tags>` only from the menu that opens when you type `<` (vocal bursts such as `<chuckles>`, `<breath>`, `<short pause>`). Tell the user to delete any tag the menu does not offer. A voice that worked well: Despina (smooth, middle pitch).
- **Bracket-tag TTS (Gemini style):** inline `[confident]`, `[short pause]`, `[dry, quiet]` before the sentence.
- **ElevenLabs:** check which tags the chosen model supports before using them. The wording and punctuation must carry the delivery even with no tags.
- In every case, say that unrecognised tags can be deleted because the wording still carries the meaning.

## Exports that make syncing easy

- One audio file per scene (`scene01.wav`, ...) is the easiest to sync. A single full file also works, because the voiceover-motion-graphics skill gets exact phrase timings with Whisper ASR.
- Ask for the highest quality export the tool offers (WAV, or MP3 at 44.1/48 kHz or better).

## Structure that worked for a technical explainer (about 10 scenes)

The scenes were: hook question, reframe in one line, scale of the estate (numbers), the core idea (model plus harness), the layers, how a guardrail decides, honest failures, useful real work, scorecard and tests, how to start on Monday, and a close on the title.