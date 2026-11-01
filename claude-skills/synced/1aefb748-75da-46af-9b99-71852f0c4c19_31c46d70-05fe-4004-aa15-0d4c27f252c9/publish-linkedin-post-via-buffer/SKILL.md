---
name: "publish-linkedin-post-via-buffer"
description: "Use when the user wants a LinkedIn post drafted, illustrated and published through their Buffer account using Claude in Chrome."
---

# Publish a LinkedIn post via Buffer (Claude in Chrome)

No LinkedIn connector exists in the MCP registry, so use the user's signed-in Buffer account (publish.buffer.com) in Chrome.

## 1. Topic and draft
- If no topic is given, WebSearch current trends and offer 5-7 topics. Say when you only saw headlines.
- Write the post in the user's voice: strong hook, short paragraphs, a short bullet list, a closing question, 8-10 hashtags. No invented statistics.
- Make a 1200x627 image (HTML + Playwright screenshot, dark gradient, large headline, hashtags). Read the PNG and fix text wrapping before showing it.
- Save text and image to /mnt/user-data/outputs/.
- Show the full draft and ask for an explicit OK to publish. Publishing is public and irreversible, so confirm even if the user said earlier to publish.

## 2. Publish in Buffer
1. Load Chrome tools in one ToolSearch call (tabs_context_mcp, navigate, computer, find, file_upload, javascript_tool, browser_batch).
2. tabs_context_mcp with createIfEmpty, then navigate to the user's Buffer channel calendar URL. Confirm they are signed in.
3. Click New Post, click the editor, and type the text. Newlines work with the type action.
4. Image: file_upload only accepts files the session may read and fails for cloud-workspace files. Workaround: use javascript_tool to redraw the image on a canvas in the page (gradient, shapes, text), make a File via toBlob, set it on the page's file input through DataTransfer, and dispatch a change event. Check the LinkedIn Preview shows the image.
5. Open the timing dropdown (Next Available), choose Now, then click Publish Now only after the user has approved.
6. Verify: dismiss any promo popup with its X (never accept), open the Sent tab, and confirm the post appears with today's date.

## Notes
- Free plan: 3 channels. Timezone shown is the user's (Riga).
- Tell the user plainly if the image was recreated instead of uploaded as the original file.
- Do not click promotional prompts or change account settings.