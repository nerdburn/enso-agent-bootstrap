# enso-dm-bridge

A small, self-contained add-on (outside the managed `install.sh` flow) that gives
one person — the **owner** — a private heads-up about their *own* unread Slack DMs,
so they don't miss anything. It reads the owner's direct and group DMs with the
**owner's own user token** and posts a digest to them via the dorian bot token.

It only ever touches the owner's own conversations — the same ones they read in
their own Slack client — and runs with the owner's own authorization. It is a
triage aid for one inbox, not a way to read anyone else's messages.

> **Consent is built into the setup.** The read token (`xoxp-`) can only be
> created by the owner approving the OAuth consent screen in their own browser.
> No one can mint it on their behalf. Keep it that way.

## Pieces

| file | what it is |
|------|------------|
| `dorian-app-additions.json` | the oauth_config block to merge into dorian's existing Slack app |
| `oauth.py` | builds the consent URL, exchanges the code for the `xoxp-` token |
| `bridge.py` | the poller: reads the owner's DMs, posts a digest |
| `enso-dm-bridge.service` / `.timer` | systemd `--user` units, every 5 min |

This reuses **dorian-agent's existing Slack app** rather than a separate app, so
there is nothing new to install in the workspace — you only add user scopes to
the app dorian already uses, and the digest is delivered by dorian's own bot
token. (A separate app is more self-documenting if you ever audit scopes; both
enforce consent identically.)

## Setup

### 1. Add user scopes to dorian's app (bot admin)
https://api.slack.com/apps → open the **dorian** app → **App Manifest**. Merge
in `dorian-app-additions.json`: add the `user` scope array alongside the existing
`bot` array, and add `redirect_urls`. **Do not** remove dorian's bot scopes or
socket-mode settings. Save.

No bot reinstall is required — adding *user* scopes does not rotate the `xoxb-`
token or drop dorian's socket connection; the user token is granted separately in
step 2. On **Basic Information**, copy the **Client ID** and **Client Secret**.

### 2. Owner authorizes (only the owner can do this)
On the VM, with the app creds in the env:

```sh
mkdir -p ~/.config/enso-agent
cat >> ~/.config/enso-agent/dm-bridge.env <<'EOF'
DM_BRIDGE_CLIENT_ID=...
DM_BRIDGE_CLIENT_SECRET=...
DM_BRIDGE_OWNER_ID=U05D4PSP08Z
EOF
chmod 600 ~/.config/enso-agent/dm-bridge.env

set -a; . ~/.config/enso-agent/dm-bridge.env; set +a
python3 contrib/enso-dm-bridge/oauth.py url
```

Send the printed URL **to the owner**. They open it, approve, and land on a
`https://localhost/dm-bridge/oauth?code=…` page that won't load — the `code` is
in the address bar. They send that URL (or just the code) back. Then:

```sh
python3 contrib/enso-dm-bridge/oauth.py exchange '<the url or code they sent>'
```

That stores `DM_BRIDGE_USER_TOKEN` (mode 600). The token value is never printed.

### 3. Notify token
The digest is delivered by **dorian's own bot token** (same app). enso keeps that
`xoxb-` in `~/.enso/config.json` (mode 600), not in an env file, so copy it into
the bridge env as `DM_BRIDGE_NOTIFY_TOKEN`:

```sh
echo 'DM_BRIDGE_NOTIFY_TOKEN=xoxb-...' >> ~/.config/enso-agent/dm-bridge.env
```

(Refer to it by name; don't echo the value into logs or chat.)

### 4. Install the timer

```sh
cp contrib/enso-dm-bridge/enso-dm-bridge.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now enso-dm-bridge.timer
# first run just records cursors; subsequent runs send digests
systemctl --user start enso-dm-bridge.service
journalctl --user -u enso-dm-bridge.service -n 20
```

## Options (in `dm-bridge.env`)

- `DM_BRIDGE_DIGEST_ONLY=1` (default) — report only *who / where / count*, no
  message text. Set `0` to include a short preview snippet per conversation.
- `DM_BRIDGE_VIP_IDS=U123,U456` — flag these senders with ⭐.
- `DM_BRIDGE_KEYWORDS=urgent,asap,blocker` — flag messages containing these.

## Notes

- The owner is a party to every DM the bridge reads, and the digest goes only to
  the owner. Still, group DMs include other people; `DIGEST_ONLY=1` keeps their
  words out of the agent by default.
- Revoke any time: the owner removes the app at
  https://slack.com/apps/manage, or you delete `DM_BRIDGE_USER_TOKEN` and stop
  the timer (`systemctl --user disable --now enso-dm-bridge.timer`).
- The state file (`~/.config/enso-agent/dm-bridge-state.json`) holds only
  per-conversation timestamps, never message content.
