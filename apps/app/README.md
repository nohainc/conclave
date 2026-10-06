# Conclave AX

Conclave AX is the Flutter application for human authentication, Projects,
Workstreams, Chat, Work, Workspace access, Worker catalog visibility, and
account security. The Workstream Chat tab is the human discussion surface;
Work remains the execution surface.
Logout sends an authenticated JSON request and clears the local session token
after Cloud confirms success. Failed logout retains the session for retry.

AX's shared `ConclaveMarkdownBody` renders authored content as explicit GitHub
Flavored Markdown with selectable text and soft line breaks. Its theme-derived
style sheet covers headings, emphasis, code, quotes, lists, read-only task lists,
tables, links and rules. HTML is not rendered. Source stays an ordinary Markdown
string through storage and Worker execution; diagnostics stay plain text.
The canonical [Workstream authored-content contract](../../docs/specifications/WORK_V1_CONTRACT.md#workstream-authored-content-contract)
keeps Chat `body`, Work `originalRequest`, Worker `finalText` and Step
`resultText` as source strings. Existing plain text remains valid Markdown.
No generated HTML, AST, renderer data or `contentFormat` field is persisted.
Links are validated as absolute HTTP/HTTPS URLs without embedded credentials
and opened outside AX using `url_launcher`. Other schemes and malformed URLs
are rejected. Markdown images display an indicator and alt text without loading
their source; controlled images belong to the attachment system.
Chat messages, Work prompts and Worker responses use this renderer, as do
original requests and Step results in Run Details. Errors, eligibility failures
and stable diagnostic codes remain plain selectable text. Copy and edit actions
continue to use the original source. Entire authored messages use **Copy
Markdown**, preserving formatting markers, links and whitespace. **Copy code**
copies only the code body; rendered text selection remains available for plain
text. Diagnostics retain their specific error-copy labels.

Chat input uses the reusable `MarkdownComposer`: Write edits raw multiline
source, and Preview uses the shared renderer. Its toolbar formats selections
as emphasis, headings, code, quotes, links and lists. Cmd/Ctrl+B, I and E apply
bold, italic and inline code. Enter inserts a newline; Cmd/Ctrl+Enter or the
Send button submits the source. Chat uses a compact bordered input with its Send
button inline. Markdown controls are hidden by default; the formatting toggle
reveals a row below the input with Write/Preview and formatting actions. Chat
places Preview after the formatting icons, replacing it with Write in the same
row during preview, with a Send button beside Write and no send icon below the
preview. Authored messages and the Chat input use regular 16px system sans-serif
text with 1.6 line height and theme-appropriate near-white/dark text. Chat
inputs and message editors have no placeholder hint.
Sending from Preview returns the composer to Write mode. Chat timestamps always
include the local date and time, including newly sent messages before refresh.
Own-message footers align right in date/time, edit, copy order; other-message
footers align left in copy, edit, date/time order.
Conclave response timestamps follow the action icons directly in the left-aligned
footer. Work errors use the same message font, size and line height as Chat,
with red as their semantic color.
Own Chat bubbles use the active navigation background (a light accent wash in
light mode). Other bubbles stay transparent; both have no outline border.
Chat and Work keep their composers and action controls fixed at the bottom of
the Workstream page. Only message history scrolls. Long Markdown previews scroll
inside a bounded preview area so they cannot displace the controls.
Existing Chat messages open the same composer in compact mode with their
original raw source, including formatting markers. Cmd/Ctrl+Enter saves edits;
Save and Cancel remain available. Link insertion selects the `url` placeholder
for replacement.

Work prompts use the same compact composer with multiline editing and no hint.
Markdown icons are hidden by default behind the formatting toggle and appear
below the input; Preview switches to Write in that row. Work messages use the
same borderless bubbles, own-prompt background and alignment as Chat.
Work uses the same send icon beside the formatting toggle to start execution;
Cmd/Ctrl+Enter also sends the request. A second row contains a plus menu for
files, links and workflow choices, followed by refresh/settings icons and the
selected workflow name. Revealed Markdown tools share that second row, with
horizontal scrolling when needed. The plus menu opens above its icon with the
same 10px corner radius as the input.
The original Markdown source is submitted unchanged, including whitespace and
fenced code. Viewer access and submission readiness still gate execution.

Fenced code uses a distinct themed block with its language label, horizontal
scrolling, selectable content and Copy code. Syntax coloring supports Dart,
TypeScript/JavaScript, JSON, YAML, SQL, Bash, Python, HTML and CSS, including
common short language aliases. Unknown tags and blocks over 50,000 characters
remain plain monospace code. Copy preserves code whitespace and trailing lines.

Run failures include a **Copy Run error** icon that copies the full message.
Worker replies appear as compact Conclave messages in Work history. Failed
Step diagnostics and implementation details are available from the **Run
details** info action, keeping the main timeline focused on the response.
AX sends commands and reads history over HTTP, with WebSocket notifications
triggering immediate history refresh. It subscribes to the active Workstream
and resynchronizes after reconnecting. While Work is queued, running, or waiting,
a five-second HTTP refresh also reconciles progress and completion if a live
notification is missed. The fallback stops after completion or leaving the page.
To enable Direct, open **Project → Workspaces → Edit Workspace access** (shield
icon), select **Read repository files** and **Change repository files**, then
confirm. Test steps also require **Execute commands and tests**. Both Workspace
connection flows present these choices explicitly; permissions are never
automatically widened. Existing connections retain their permissions.

The package intentionally has no native desktop targets. Desktop execution is
provided by Conclave Workspace; Conclave AX communicates with Cloud through
the Human Product Protocol and realtime event stream.

If live data cannot load, the recovery screen shows the failing resource,
HTTP status, and Cloud's JSON error detail when available. **Copy error**
copies that message with recovery context; **Try again** reloads the data.
Error text is also selectable. Non-JSON proxy responses use the resource
and status without copying the response page.

Worker availability is derived from Cloud's readiness and activation fields.
Enabled, Ready Workers count as available; disabled Workers do not. Worker
cards distinguish unchecked, sign-in, Profile/runtime, setup, and test failures
instead of treating a missing legacy status field as “Needs attention”.

## Getting Started

Markdown regression coverage includes toolbar selection transformations,
quote/unquote, GFM rendering in both themes, unsafe links, blocked network
images, malformed content, keyboard submission, and lossless Chat create/edit
and message copying. Cloud contract tests exercise SQLite-backed Chat storage
and Work history/details with Markdown delimiters and fenced code. Work
execution regression tests also forward the original Markdown prompt unchanged.
Chat validates nonblank content without trimming its stored source.

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
