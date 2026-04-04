# Shared Rules

`Shared Rules` is the optional GitHub-backed list used by the GL router in `selective` mode.

## What The List Contains

The canonical file can contain:

- domains
- IPv4 addresses
- CIDR blocks

The operator edits one human-facing list. The router then turns that list into runtime state.

## How GL Uses It

On the GL router:

- literal IPv4 / CIDR entries go straight into the live `ipset`
- domain entries are tracked through `dnsmasq -> ipset`
- a resolved IPv4 snapshot is kept for diagnostics only

This means domain-based selective routing follows later DNS changes without requiring a full manual rebuild every time an address changes.

## GitHub Sync Model

The router polls the Git repo in the background every `30s` by default.

The UI shows a compact live status:

- whether background checks are running
- what phase the sync engine is in
- whether GitHub and runtime are already aligned
- when the last full verification finished

If there is no upstream change, the router does not reapply the ruleset unnecessarily.

## Conflict Policy

GitHub is treated as canonical during a real conflict.

If both sides changed:

- the router starts from the GitHub version
- truly unique local lines are appended to the end
- the router creates a new commit on top of GitHub with the conflict already resolved

If GitHub did not change, local edits are saved exactly as entered, including deletions.

## Runtime Cutover

The UI and the background sync engine both track whether the runtime still matches the latest verified ruleset.

If a reset / cutover is needed, the status reflects that directly instead of leaving the operator to guess why existing connections still behave like the old rules.
