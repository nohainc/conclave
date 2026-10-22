# Account security UI

On the Account page, Google and GitHub unlink icons open a confirmation dialog
naming the provider. The dialog explains that the linked account will no longer
be available for sign-in and asks the user to ensure another sign-in method is
available.

Cancel or dismissing the dialog leaves the account linked and sends no unlink
request. Only selecting Unlink submits the existing unlink operation. A session
change while the dialog is open prevents submission. During submission, unlink
actions are disabled; failures retain the linked account and display the error.
Server-side sign-in-method safeguards remain authoritative.

Account action icons use 20px glyphs within 48px click targets. Provider actions,
session revoke actions, and account deletion share the right edge of the page.
Revoke all remains a text action.
