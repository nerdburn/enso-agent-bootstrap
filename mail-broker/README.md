# agent-mail broker

Every agent's Claude seat is an alias of **agent@inputlogic.ca** (athena@, joan@,
abbe@, …), so all their mail lands in one inbox. This Apps Script, deployed in
that mailbox, is the only thing with access to it. Each agent VM gets a key that
maps to its own alias, and the script applies that scope itself:

- a message is visible only if its `To`/`Cc`/`Delivered-To`/`X-Original-To`
  holds the agent's alias, so mail to another alias, or only to agent@, is never returned;
- and only from an allowed sender domain that Gmail authenticated (DMARC pass,
  or a passing DKIM signature from that domain), so a spoofed `From:` is dropped.
- It's read-only (`gmail.readonly`): no send, label or delete. Script
  Properties hold only SHA-256 hashes of the keys.

Agents use it through `agent-mail` (`bin/agent-mail`, installed by `install.sh`).

**Drive** ([`Drive.gs`](Drive.gs), `agent-docs` on the VM): every alias is the
same Google user, so Drive can't say whose a share was, but Google's share
notification email goes to the alias. An agent may open a Drive file only if a
share email to its alias (from Google's share sender, authenticated) names that
file, or a folder above it. When the subject quotes a file name, only links
whose Drive name matches it count, so links pasted into the sharer's message
grant nothing. Docs come back as Markdown, Sheets as CSV per tab, Slides as
text, and other files as bytes. It's read-only. For a file shared without a
notification, the operator can grant it by hand: admin op `grant`
(`{"admin": …, "op": "grant", "alias": "athena@inputlogic.ca", "id": "<link or id>"}`),
plus `ungrant` and `grants`.

## One-time deploy (signed in as agent@inputlogic.ca)

1. https://script.google.com → **New project**, name it `agent-mail broker`.
2. **Project Settings** (gear) → tick *Show "appsscript.json" manifest file in editor*.
3. **Editor**: replace `Code.gs` with [`Code.gs`](Code.gs), add a script file
   `Drive` with [`Drive.gs`](Drive.gs), and replace `appsscript.json` with
   [`appsscript.json`](appsscript.json) (it also enables the Gmail, Drive and
   Sheets services). Save.
4. Pick `setup` in the function menu → **Run** → authorize. Every scope is
   read-only: view email, see and download Drive files, see spreadsheets, plus
   "connect to an external service" (the script calling the Drive and Sheets
   APIs). The log names the mailbox; it must be agent@inputlogic.ca.
5. **Deploy → New deployment** → type *Web app*, execute as **Me**, access
   **Anyone** → Deploy. Copy the web app URL (`https://script.google.com/macros/s/…/exec`)
   into `~/.config/enso-agent-bootstrap/defaults.conf` as `AGENT_MAIL_URL="…"`.
   "Anyone" only means anyone can reach it: every request still needs a key.
6. The first `./bootstrap.sh mail-key <conf>` **claims** the broker. It generates
   the admin key into `~/.config/enso-agent-bootstrap/agent-mail-admin-key`
   (mode 600) and sends it once; the broker keeps its hash and refuses any later
   claim. The admin key never shows up in a browser or a log.

## Per agent (laptop)

```
# in the agent's conf: the agent's Claude address
AGENT_EMAIL="athena@inputlogic.ca"

./bootstrap.sh mail-key athena.conf   # mints the key into the conf (re-run rotates it)
./bootstrap.sh deploy athena.conf     # ships it; install.sh checks `agent-mail whoami`
```

## Changing it later

- **Code changes**: paste the new `Code.gs`, then **Deploy → Manage deployments
  → edit → Version: New version**. Editing an existing deployment keeps the URL.
  A *new* deployment gets a new URL.
- **Sender allowlist**: defaults to the service domains in `DEFAULT_ALLOW`;
  read or replace it with the admin op `allow` (`{"admin": …, "op": "allow",
  "senders": "anthropic.com,github.com,…"}`). `*` allows every sender, which isn't recommended:
  anyone can email an alias.
- **Revoke an agent**: admin op `revoke` with its `alias`; `agents` lists them.
- **Audit**: Apps Script → *Executions* logs each request's op and alias (never keys or content).
- **Rotate the admin key**: run `rotateAdmin` in the editor, delete the laptop's
  `agent-mail-admin-key`, and run `mail-key` again; agent keys survive.
