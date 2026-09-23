# Workspace usage reporting

The Usage page is a Workspace-level reporting surface, not a selected-Run
summary. Cloud returns usage rows with the Project, requester, Worker, Account
and Account owner so shared credentials remain attributable without exposing
secrets.

Each row has a `billingCategory`: `api`, `subscription`, `local`, or `unknown`.
Only API rows with a recorded `costMicros` contribute to known API cost.
Subscription-backed Workers are shown as usage counts and token/duration data;
Conclave never invents a monetary price for a subscription.

The read model supports period, Project, requester, Account, Worker,
provider/model, and custom date filters. Workspace authorization is applied by
Cloud before rows are returned.
