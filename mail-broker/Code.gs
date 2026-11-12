/**
 * agent-mail broker — Google Apps Script web app, deployed in the shared
 * agent@inputlogic.ca mailbox (see README.md here).
 *
 * Every agent's Claude seat is an alias of agent@ (athena@, joan@, abbe@, …),
 * so all their mail lands in one inbox. This script is the only thing with
 * access to it. Each agent VM holds a key that maps to its own alias, and the
 * script applies that scope itself: an agent sees only messages addressed to
 * its alias (To/Cc/Delivered-To/X-Original-To), from an allowed, authenticated
 * sender. It is read-only (gmail.readonly) and never sends, labels or deletes.
 *
 * Requests are POSTs with a JSON body (keys never go in the URL):
 *   {key, op: "whoami"}
 *   {key, op: "search", q?, max?}         → newest first, max ≤ 50
 *   {key, op: "read", id, max_chars?}     → headers, text body, links
 * Drive files shared with the alias: ops "docs" and "doc", see Drive.gs.
 * Admin (the operator's admin key):
 *   {claim, op: "claim"}                  → first request only: sets the admin key
 *                                           (the first bootstrap.sh mail-key); refused once set
 *   {admin, op: "register", alias}        → {key}; replaces that alias's old key
 *   {admin, op: "revoke", alias}
 *   {admin, op: "agents"}                 → registered aliases
 *   {admin, op: "allow", senders?}        → read or set the sender allowlist
 *
 * Stored in Script Properties: only SHA-256 hashes of keys, never the keys.
 */

var DEFAULT_ALLOW = [
  'anthropic.com', 'claude.ai', 'claude.com', 'github.com', 'vercel.com',
  'cloudflare.com', 'heroku.com', 'neon.tech', 'sanity.io', 'stripe.com',
  'slack.com', 'figma.com', 'google.com', 'exe.dev'
].join(',');
var MAX_SEARCH = 50;
var DEFAULT_CHARS = 20000;
var ADDR_HEADERS = ['To', 'Cc', 'Delivered-To', 'X-Original-To'];
var META_HEADERS = ['From', 'To', 'Cc', 'Delivered-To', 'X-Original-To', 'Subject', 'Date', 'Authentication-Results'];

// ── Run once from the editor ───────────────────────────────────────────────
/** Authorizes the script (run once from the editor) and reports its state. */
function setup() {
  var props = PropertiesService.getScriptProperties();
  Logger.log('Mailbox: ' + Gmail.Users.getProfile('me').emailAddress +
    '. Admin: ' + (props.getProperty('admin') ? 'claimed' : 'unclaimed (the first ./bootstrap.sh mail-key claims it)'));
}

/** Drops the admin key; the next mail-key run claims it again. Agent keys stay. */
function rotateAdmin() {
  PropertiesService.getScriptProperties().deleteProperty('admin');
  Logger.log('Admin key cleared. Delete agent-mail-admin-key on the laptop and run ./bootstrap.sh mail-key <conf> to claim again.');
}

// ── Web app ─────────────────────────────────────────────────────────────────
function doPost(e) {
  var req;
  try {
    req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return json_({error: 'body is not JSON'});
  }
  try {
    if (req.op === 'claim') return json_(claim_(req));
    if (req.admin) return json_(admin_(req));
    var alias = aliasFor_(req.key);
    if (!alias) return json_({error: 'unauthorized'});
    console.log(JSON.stringify({op: req.op, alias: alias}));
    switch (req.op) {
      case 'whoami': return json_({alias: alias});
      case 'search': return json_(search_(alias, req));
      case 'read':   return json_(read_(alias, req));
      case 'docs':   return json_(docs_(alias, req));   // Drive.gs
      case 'doc':    return json_(doc_(alias, req));
      default:       return json_({error: 'unknown op: ' + req.op});
    }
  } catch (err) {
    console.error(err);
    return json_({error: String(err && err.message || err)});
  }
}

function doGet() {
  return json_({error: 'POST a JSON body; see the agent-mail CLI'});
}

// ── Agent ops ───────────────────────────────────────────────────────────────
function search_(alias, req) {
  var max = Math.max(1, Math.min(MAX_SEARCH, parseInt(req.max, 10) || 10));
  var q = String(req.q || 'newer_than:7d').replace(/[{}]/g, ' ');
  // The query narrows; checkMessage_ is what actually enforces the scope.
  var full = '(' + q + ') {to:' + alias + ' deliveredto:' + alias + '}';
  var out = [];
  var pageToken;
  var scanned = 0;
  do {
    var page = Gmail.Users.Messages.list('me', {q: full, maxResults: 100, pageToken: pageToken});
    var ids = (page.messages || []);
    for (var i = 0; i < ids.length && out.length < max; i++) {
      scanned++;
      var m = Gmail.Users.Messages.get('me', ids[i].id, {format: 'metadata', metadataHeaders: META_HEADERS});
      var h = headers_(m);
      if (!checkMessage_(alias, h).ok) continue;
      out.push({
        id: m.id,
        date: first_(h, 'Date'),
        from: first_(h, 'From'),
        subject: first_(h, 'Subject'),
        snippet: decodeEntities_(m.snippet || '')
      });
    }
    pageToken = page.nextPageToken;
  } while (pageToken && out.length < max && scanned < 300);
  return {alias: alias, messages: out};
}

function read_(alias, req) {
  if (!req.id || !/^[A-Za-z0-9]+$/.test(String(req.id))) return {error: 'id required'};
  var m;
  try {
    m = Gmail.Users.Messages.get('me', String(req.id), {format: 'full'});
  } catch (err) {
    return {error: 'not found'};
  }
  var h = headers_(m);
  var check = checkMessage_(alias, h);
  // Same answer whether the message is someone else's or missing.
  if (!check.ok) return {error: 'not found'};
  var bodies = {plain: [], html: []};
  collectBodies_(m.payload, bodies);
  var html = bodies.html.join('\n');
  var text = bodies.plain.join('\n') || htmlToText_(html);
  var maxChars = Math.max(1000, Math.min(200000, parseInt(req.max_chars, 10) || DEFAULT_CHARS));
  return {
    alias: alias,
    id: m.id,
    date: first_(h, 'Date'),
    from: first_(h, 'From'),
    to: first_(h, 'To'),
    cc: first_(h, 'Cc'),
    subject: first_(h, 'Subject'),
    sender_verified: check.verified,
    text: text.length > maxChars ? text.slice(0, maxChars) + '\n[… truncated]' : text,
    links: links_(html, text)
  };
}

// ── Scope and sender checks ─────────────────────────────────────────────────
function checkMessage_(alias, h) {
  var a = alias.toLowerCase();
  var addressed = ADDR_HEADERS.some(function (name) {
    return (h[name.toLowerCase()] || []).some(function (v) {
      return addresses_(v).indexOf(a) !== -1;
    });
  });
  if (!addressed) return {ok: false};
  var fromDomain = domainOf_(addresses_(first_(h, 'From'))[0] || '');
  var allow = allowList_();
  if (allow.indexOf('*') !== -1) return {ok: true, verified: authenticated_(h, fromDomain)};
  if (!matchesDomain_(fromDomain, allow)) return {ok: false};
  // An allowed From: domain only counts when Gmail authenticated it.
  if (!authenticated_(h, fromDomain)) return {ok: false};
  return {ok: true, verified: true};
}

/** DMARC pass for the From: domain, or a passing DKIM signature from it. */
function authenticated_(h, fromDomain) {
  if (!fromDomain) return false;
  var ar = (h['authentication-results'] || []).join(';').toLowerCase();
  var dmarc = /dmarc=pass[^;]*header\.from=([a-z0-9.-]+)/g, mm;
  while ((mm = dmarc.exec(ar))) if (sameOrSub_(fromDomain, mm[1])) return true;
  var dkim = /dkim=pass[^;]*header\.(?:i|d)=@?([a-z0-9.-]+)/g;
  while ((mm = dkim.exec(ar))) if (sameOrSub_(fromDomain, mm[1]) || sameOrSub_(mm[1], fromDomain)) return true;
  return false;
}

function allowList_() {
  var raw = PropertiesService.getScriptProperties().getProperty('allow') || DEFAULT_ALLOW;
  return raw.split(/[\s,]+/).map(function (s) { return s.trim().toLowerCase(); }).filter(String);
}

function matchesDomain_(domain, list) {
  return list.some(function (d) { return sameOrSub_(domain, d); });
}

function sameOrSub_(domain, parent) {
  domain = (domain || '').toLowerCase(); parent = (parent || '').toLowerCase();
  return !!domain && !!parent && (domain === parent || domain.slice(-(parent.length + 1)) === '.' + parent);
}

// ── Admin ───────────────────────────────────────────────────────────────────
/** Sets the admin key once, so it never has to be copied out of a log. */
function claim_(req) {
  var lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    var props = PropertiesService.getScriptProperties();
    if (props.getProperty('admin')) return {error: 'already claimed (run rotateAdmin() in the editor to start over)'};
    var key = String(req.claim || '');
    if (!/^[A-Za-z0-9]{40,}$/.test(key)) return {error: 'claim key must be 40+ letters/digits'};
    props.setProperty('admin', sha256_(key));
    if (!props.getProperty('allow')) props.setProperty('allow', DEFAULT_ALLOW);
    console.log('claimed');
    return {claimed: true};
  } finally {
    lock.releaseLock();
  }
}

function admin_(req) {
  var props = PropertiesService.getScriptProperties();
  var stored = props.getProperty('admin');
  if (!stored || sha256_(String(req.admin)) !== stored) return {error: 'unauthorized'};
  console.log(JSON.stringify({admin: req.op, alias: req.alias || ''}));
  var all = props.getProperties();
  switch (req.op) {
    case 'register': {
      var alias = String(req.alias || '').trim().toLowerCase();
      if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(alias)) return {error: 'alias must be an email address'};
      removeAlias_(props, all, alias);
      var key = newKey_();
      props.setProperty('agent:' + sha256_(key), alias);
      return {alias: alias, key: key};
    }
    case 'revoke': {
      var a = String(req.alias || '').trim().toLowerCase();
      return {alias: a, removed: removeAlias_(props, all, a)};
    }
    case 'agents':
      return {aliases: Object.keys(all).filter(function (k) { return k.indexOf('agent:') === 0; })
        .map(function (k) { return all[k]; }).sort()};
    case 'allow':
      if (req.senders !== undefined) props.setProperty('allow', String(req.senders));
      return {allow: allowList_()};
    default:
      return driveAdmin_(req, props) || {error: 'unknown admin op: ' + req.op};   // Drive.gs
  }
}

function removeAlias_(props, all, alias) {
  var n = 0;
  Object.keys(all).forEach(function (k) {
    if (k.indexOf('agent:') === 0 && all[k] === alias) { props.deleteProperty(k); n++; }
  });
  return n;
}

function aliasFor_(key) {
  if (!key || String(key).length < 32) return null;
  return PropertiesService.getScriptProperties().getProperty('agent:' + sha256_(String(key)));
}

// ── Helpers ─────────────────────────────────────────────────────────────────
function headers_(m) {
  var h = {};
  ((m.payload && m.payload.headers) || []).forEach(function (x) {
    var k = x.name.toLowerCase();
    (h[k] = h[k] || []).push(x.value);
  });
  return h;
}

function first_(h, name) {
  return (h[name.toLowerCase()] || [''])[0];
}

/** Bare, lowercased addresses in a header value. */
function addresses_(v) {
  return (String(v || '').match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) || [])
    .map(function (s) { return s.toLowerCase(); });
}

function domainOf_(addr) {
  var i = addr.lastIndexOf('@');
  return i === -1 ? '' : addr.slice(i + 1).toLowerCase();
}

function collectBodies_(part, out) {
  if (!part) return;
  var type = (part.mimeType || '').toLowerCase();
  var isAttachment = part.filename && part.filename.length > 0;
  if (!isAttachment && part.body && part.body.data && (type === 'text/plain' || type === 'text/html')) {
    var s = Utilities.newBlob(bodyBytes_(part.body.data)).getDataAsString('UTF-8');
    (type === 'text/plain' ? out.plain : out.html).push(s);
  }
  (part.parts || []).forEach(function (p) { collectBodies_(p, out); });
}

/** The Gmail service hands body data back as bytes or as unpadded base64url. */
function bodyBytes_(data) {
  if (Array.isArray(data)) return data;
  var b64 = String(data).replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  while (b64.length % 4) b64 += '=';
  return Utilities.base64Decode(b64);
}

function htmlToText_(html) {
  return decodeEntities_(String(html || '')
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ''))
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

function decodeEntities_(s) {
  return String(s).replace(/&#(\d+);/g, function (_, n) { return String.fromCharCode(+n); })
    .replace(/&#x([0-9a-f]+);/gi, function (_, n) { return String.fromCharCode(parseInt(n, 16)); })
    .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
}

function links_(html, text) {
  var seen = {}, out = [];
  function add(u) {
    u = decodeEntities_(u).trim();
    if (/^https?:\/\//i.test(u) && !seen[u]) { seen[u] = true; out.push(u); }
  }
  var re = /href\s*=\s*["']([^"']+)["']/gi, m;
  while ((m = re.exec(html || ''))) add(m[1]);
  (String(text || '').match(/https?:\/\/[^\s<>"')\]]+/g) || [])
    .forEach(function (u) { add(u.replace(/[.,;:!?]+$/, '')); });
  return out.slice(0, 200);
}

function newKey_() {
  return (Utilities.getUuid() + Utilities.getUuid()).replace(/-/g, '');
}

function sha256_(s) {
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, s, Utilities.Charset.UTF_8)
    .map(function (b) { return ('0' + (b & 0xff).toString(16)).slice(-2); }).join('');
}

function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
