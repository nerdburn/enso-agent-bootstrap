---
name: Operator
description: Confirmed operator identity, locale, communication preferences, and standing personal context; read when a task depends on those facts.
---

# Operator

This is an editable record of durable personal context confirmed with the operator.
Do not infer missing facts from usernames, device settings, message metadata, or prior
guesses. Never record secrets or credential values; record only an approved credential
location when routing requires it.

## Confirmed identity

- Name: __OPERATOR_NAME__
- Slack user ID(s) with administrative DM access: __SLACK_OWNER_IDS__
- This agent's name is __AGENT_NAME__; it runs on exe.dev VM `__VM_NAME__`.

## Locale and timezone

- Timezone: __TIMEZONE__ (the VM clock and all job schedules use this timezone).

## Communication preferences

- Concise replies; the operator usually reads them on a phone.
- Confirm before destructive or shared-state changes; otherwise act first.

## Standing personal context

- No confirmed facts yet.

Replace a placeholder only after confirmation, and keep context that should instead
live in a project repository or configured knowledge base at that authoritative source.
