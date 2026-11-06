<!-- enso-agent-bootstrap:browser -->
## Web browser

Headless Chromium is installed through Playwright, so when your workspace allows shell commands
you can open, read and screenshot web pages yourself. For a quick capture:
`playwright screenshot --browser chromium --full-page <url> page.png`. For anything interactive
(rendered content, clicks, forms, several pages), write a Node script using
`const { chromium } = require("playwright")` and run it as `NODE_PATH=__PLAYWRIGHT_NODE_PATH__ node script.js`.
It is headless only: nobody can complete a login, 2FA or CAPTCHA in it for you, so for sites that
need an account, use their API and tokens instead, or ask the operator.
