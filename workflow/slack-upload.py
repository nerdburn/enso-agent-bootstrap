#!/usr/bin/env python3
"""Upload files into a Slack thread as the agent's bot (files:write).

    slack-upload.py CHANNEL THREAD_TS FILE [FILE...]

enso's `message attach` posts top-level only; screenshots for a signoff belong in the
notice's thread. The bot token is read from ~/.enso/config.json and never printed.
Best effort: prints what it uploaded, exits non-zero on failure.
"""
import json
import mimetypes
import os
import sys
import urllib.parse
import urllib.request


def token() -> str:
    home = os.environ.get("ENSO_HOME") or os.path.expanduser("~/.enso")
    stack = [json.load(open(os.path.join(home, "config.json")))]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, str) and node.startswith("xoxb-"):
            return node
    sys.exit("slack-upload: no Slack bot token in config.json")


def api(method: str, tok: str, **params: str) -> dict:
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"https://slack.com/api/{method}", data=data,
                                 headers={"Authorization": f"Bearer {tok}"})
    reply = json.load(urllib.request.urlopen(req, timeout=60))
    if not reply.get("ok"):
        raise RuntimeError(f"{method}: {reply.get('error')}")
    return reply


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    channel, thread, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    tok = token()
    files = []
    for path in paths:
        name = os.path.basename(path)
        body = open(path, "rb").read()
        slot = api("files.getUploadURLExternal", tok, filename=name, length=str(len(body)))
        req = urllib.request.Request(slot["upload_url"], data=body, method="POST",
                                     headers={"Content-Type": mimetypes.guess_type(name)[0] or "application/octet-stream"})
        urllib.request.urlopen(req, timeout=120).read()
        files.append({"id": slot["file_id"], "title": name})
    extra = {"initial_comment": os.environ["SLACK_UPLOAD_COMMENT"]} if os.environ.get("SLACK_UPLOAD_COMMENT") else {}
    api("files.completeUploadExternal", tok, files=json.dumps(files), channel_id=channel, thread_ts=thread, **extra)
    print(f"uploaded {len(files)} file(s) to {channel} thread {thread}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
