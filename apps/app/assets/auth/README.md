# Account provider icons

Official provider assets, downloaded from:

- GitHub: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
- Google: https://developers.google.com/identity/images/g-logo.png

The account page uses these marks for both link actions and linked methods.
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
links and Delete account use underlined text links in one horizontally scrollable
row, keeping one row even on narrow screens. Connected providers still hide
their link actions. Link icons use alternative official 24px assets:

- GitHub: https://github.githubassets.com/favicons/favicon.png
- Google: https://www.google.com/images/branding/googleg/1x/googleg_standard_color_128dp.png

Links support keyboard focus and activation and expose link semantics.
Linked-method marks remain 24px.

Session rows inherit the app's body typography: a 13px medium-weight browser
label, a 12px secondary expiry line, muted 20px device icons, and matching small
status/action text. Icons, details, and trailing status/actions align at the top
so wrapped labels do not shift controls vertically. Current is a status label,
not a disabled button. Expiry timestamps display as “Expires 7 Oct 2026, 10:00
UTC”; missing or invalid timestamps display “Expiry unavailable”.
