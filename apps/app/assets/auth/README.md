# Account provider icons

Official provider assets, downloaded from:

- GitHub: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
- Google: https://developers.google.com/identity/images/g-logo.png

Account marks are transparent 128px PNGs cropped edge-to-edge so both render
at the same visual size; GitHub is tinted with the theme text color.
The login page uses the official GitHub and Google marks at 20px in matching
outlined provider buttons. Account settings also use these marks for linked methods.
A provider's link action is hidden once that provider appears in the loaded
account security data (case-insensitive). Credential accounts remain hidden.
Session rows show a compact best-effort browser/device label in small text,
rather than full browser user-agent strings. Unrecognized long strings fall
back to “Browser session”; session identity and revocation use server IDs/tokens.

The profile header has inline name/email edits and a Delete account action.
Account removal retains its confirmation dialog. Clicking the avatar opens the existing
image picker; its tooltip and upload indicator expose the action and busy state.
Linked methods and available link buttons appear without a section heading or
empty-state message. Connected providers continue to hide their link buttons.
Session rows use flexible text space and explicit surface colors in both themes;
missing or invisible user-agent metadata displays “Browser session”.

Name and email edits open from accessible edit icons immediately after each
value; separate Rename and Update email buttons are omitted. Available provider
links and Delete account use text links without underlines in one horizontally scrollable
row, keeping one row even on narrow screens. Connected providers still hide
their link actions. Link icons use alternative official 16px marks:

- GitHub: https://github.githubassets.com/favicons/favicon.png
- Google: https://www.google.com/images/branding/googleg/1x/googleg_standard_color_128dp.png

Links support keyboard focus and activation and expose link semantics.
Linked-method marks remain 24px.

Session rows inherit the app's body typography: a 13px medium-weight browser
label, a 12px white expiry line, 18px white device icons, and matching small
status/action text. Icons, details, and trailing status/actions align at the top
so wrapped labels do not shift controls vertically. Current is a status label,
not a disabled button. Expiry timestamps display as “Expires 7 Oct 2026, 10:00
UTC”; missing or invalid timestamps display “Expiry unavailable”.

Session browser labels and expiry details share the same left edge, with an
8px gap after the device icon. The icon aligns with the browser label rather
than the combined two-line block.

The action row follows the profile and any linked methods without section-sized
spacers. An empty linked-method list takes no layout space.

Provider action labels and all session row icons/text use explicit white per the
account-page design. All three account action labels have no underline; Delete
account retains its destructive color.
