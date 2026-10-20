# Home update presentation

What's new and AI updates share the same metadata badges, dates, typography,
spacing, summaries, and detail text on Home and in their all-items dialogs.
AI entries retain Worker attribution and model information; product entries
retain their details and hide action.

Continue working cards display the Thread title and latest message author without
a separate Space heading. Message whitespace is collapsed and previews are limited
to 200 grapheme characters, including the truncation ellipsis. The author prefix
is separate from that limit.

The Thread read model compares Discussion messages with canonical user messages
and Worker responses by message timestamp. Internal history events are excluded,
and preview text and author use the same selection. No schema migration is needed.

Regression coverage: `apps/app/test/home_page_test.dart` and
`apps/cloud/test/thread-read-model.acceptance.test.ts`.
