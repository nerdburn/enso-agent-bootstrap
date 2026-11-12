/**
 * agent-docs: Google Drive files shared with an agent's alias (read-only).
 *
 * All aliases are one Google user (agent@), so Drive itself can't tell whose a
 * share was. The share *notification* can: Google mails it to the alias. An
 * agent may open a file only if
 *   - a Drive share email addressed to its alias (from Google, authenticated,
 *     the same checks as mail) names that file or a folder above it; when the
 *     subject quotes a name, only links whose Drive name matches it count, so a
 *     link pasted into the sharer's message doesn't grant anything;
 *   - or the operator granted it by hand (admin op "grant").
 * Drive's own permissions still apply: agent@ must be able to open the file.
 *
 * Ops (agent key):
 *   {key, op: "docs"}                       → the files and folders shared with this alias
 *   {key, op: "docs", folder: id}           → a granted folder's contents
 *   {key, op: "doc", id, max_chars?}        → metadata + text (Docs → Markdown,
 *                                             Sheets → CSV per tab, Slides → text),
 *                                             or base64 for other files ≤ 20 MB
 * Admin: {admin, op: "grant"|"ungrant", alias, id}, {admin, op: "grants", alias}
 */

var SHARE_SENDERS = ['drive-shares-dm-noreply@google.com', 'drive-shares-noreply@google.com'];
var DRIVE = 'https://www.googleapis.com/drive/v3/files/';
var FILE_FIELDS = 'id,name,mimeType,parents,modifiedTime,webViewLink,size,owners(emailAddress)';
var MAX_BINARY = 20 * 1024 * 1024;
var DRIVE_ID_RE = /(?:docs\.google\.com\/(?:document|spreadsheets|presentation|forms|drawings)(?:\/u\/\d+)?\/d\/|drive\.google\.com\/(?:file\/d\/|drive\/(?:u\/\d+\/)?folders\/|open\?id=))([A-Za-z0-9_-]{20,})/g;

// ── Agent ops ───────────────────────────────────────────────────────────────
function docs_(alias, req) {
  var granted = granted_(alias);
  if (req.folder) {
    var fid = cleanId_(req.folder);
    if (!allowed_(fid, granted)) return {error: 'not found'};
    var q = encodeURIComponent("'" + fid + "' in parents and trashed = false");
    var list = api_(DRIVE + '?q=' + q + '&pageSize=200&supportsAllDrives=true&includeItemsFromAllDrives=true' +
      '&fields=' + encodeURIComponent('files(' + FILE_FIELDS + ')')).files || [];
    return {alias: alias, folder: fid, files: list.map(brief_)};
  }
  var out = [];
  Object.keys(granted).forEach(function (id) {
    var meta = fileMeta_(id);
    if (!meta) return;
    var b = brief_(meta);
    b.via = granted[id];
    out.push(b);
  });
  out.sort(function (a, b) { return String(b.via.date).localeCompare(String(a.via.date)); });
  return {alias: alias, files: out};
}

function doc_(alias, req) {
  var id = cleanId_(req.id);
  if (!id) return {error: 'id or link required'};
  var granted = granted_(alias);
  var meta = fileMeta_(id);
  // The same answer whether the file is someone else's or missing.
  if (!meta || !allowed_(id, granted, meta)) return {error: 'not found'};
  var maxChars = Math.max(1000, Math.min(500000, parseInt(req.max_chars, 10) || 100000));
  var out = brief_(meta);
  out.alias = alias;
  var t = meta.mimeType;
  var text = null;
  if (t === 'application/vnd.google-apps.document') {
    text = exportText_(id, 'text/markdown') || exportText_(id, 'text/plain');
    out.format = 'markdown';
  } else if (t === 'application/vnd.google-apps.spreadsheet') {
    text = sheetsCsv_(id);
    out.format = 'csv';
  } else if (t === 'application/vnd.google-apps.presentation') {
    text = exportText_(id, 'text/plain');
    out.format = 'text';
  } else if (t === 'application/vnd.google-apps.folder') {
    return docs_(alias, {folder: id});
  } else if (/^application\/vnd\.google-apps\./.test(t)) {
    return {error: 'this Google file type cannot be exported: ' + t};
  } else if (/^text\/|json|csv|xml|markdown/.test(t)) {
    text = media_(id).getDataAsString('UTF-8');
    out.format = 'text';
  } else {
    if (meta.size && Number(meta.size) > MAX_BINARY) return {error: 'file is larger than 20 MB'};
    out.format = 'base64';
    out.data = Utilities.base64Encode(media_(id).getBytes());
    return out;
  }
  out.text = text.length > maxChars ? text.slice(0, maxChars) + '\n[… truncated]' : text;
  return out;
}

// ── What an alias may open ──────────────────────────────────────────────────
/** {fileId: {subject, date, from}} from share emails to the alias, plus manual grants. */
function granted_(alias) {
  var cache = CacheService.getScriptCache();
  var hit = cache.get('drv2:' + alias);
  if (hit) return JSON.parse(hit);
  var out = {};
  var q = '{' + SHARE_SENDERS.map(function (s) { return 'from:' + s; }).join(' ') + '} ' +
          '{to:' + alias + ' deliveredto:' + alias + '} newer_than:730d';
  var pageToken, scanned = 0;
  do {
    var page = Gmail.Users.Messages.list('me', {q: q, maxResults: 100, pageToken: pageToken});
    (page.messages || []).forEach(function (ref) {
      scanned++;
      shareIds_(alias, ref.id).forEach(function (g) { if (!out[g.id]) out[g.id] = g.via; });
    });
    pageToken = page.nextPageToken;
  } while (pageToken && scanned < 500);
  var manual = JSON.parse(PropertiesService.getScriptProperties().getProperty('grant:' + alias) || '[]');
  manual.forEach(function (id) { if (!out[id]) out[id] = {subject: 'granted by the operator', date: '', from: ''}; });
  try { cache.put('drv2:' + alias, JSON.stringify(out), 300); } catch (e) {}
  return out;
}

/** The files one share email grants to the alias (cached per message and alias). */
function shareIds_(alias, msgId) {
  var cache = CacheService.getScriptCache();
  var key = 'shr2:' + alias + ':' + msgId;
  var complete = true;
  var hit = cache.get(key);
  if (hit) return JSON.parse(hit);
  var res = [];
  var m = Gmail.Users.Messages.get('me', msgId, {format: 'full'});
  var h = headers_(m);
  var fromAddr = (addresses_(first_(h, 'From'))[0] || '');
  if (checkMessage_(alias, h).ok && SHARE_SENDERS.indexOf(fromAddr) !== -1) {
    var bodies = {plain: [], html: []};
    collectBodies_(m.payload, bodies);
    var all = bodies.html.join('\n') + '\n' + bodies.plain.join('\n');
    all = all.replace(/%2F/gi, '/').replace(/%3F/gi, '?').replace(/%3D/gi, '=');
    var ids = {}, mm;
    DRIVE_ID_RE.lastIndex = 0;
    while ((mm = DRIVE_ID_RE.exec(all))) ids[mm[1]] = true;
    var subject = first_(h, 'Subject');
    var named = (subject.match(/["“](.+)["”]\s*$/) || [])[1];
    var via = {subject: subject, date: first_(h, 'Date'), from: first_(h, 'From')};
    Object.keys(ids).forEach(function (id) {
      if (named) {
        // Only the file the notification is about, not links in the sharer's message.
        var meta = fileMeta_(id);
        if (!meta) { complete = false; return; }
        if (meta.name.trim() !== named.trim()) return;
      }
      res.push({id: id, via: via});
    });
  }
  if (complete) { try { cache.put(key, JSON.stringify(res), 21600); } catch (e) {} }
  return res;
}

/** Granted directly, or inside a granted folder (up to 10 levels). */
function allowed_(id, granted, meta) {
  if (granted[id]) return true;
  var seen = {}, frontier = ((meta || fileMeta_(id)) || {}).parents || [];
  for (var depth = 0; depth < 10 && frontier.length; depth++) {
    var next = [];
    for (var i = 0; i < frontier.length; i++) {
      var p = frontier[i];
      if (seen[p]) continue;
      seen[p] = true;
      if (granted[p]) return true;
      var pm = fileMeta_(p);
      if (pm && pm.parents) next = next.concat(pm.parents);
    }
    frontier = next;
  }
  return false;
}

// ── Admin ───────────────────────────────────────────────────────────────────
function driveAdmin_(req, props) {
  var alias = String(req.alias || '').trim().toLowerCase();
  if (!alias) return {error: 'alias required'};
  var key = 'grant:' + alias;
  var list = JSON.parse(props.getProperty(key) || '[]');
  var id = cleanId_(req.id);
  if (req.op === 'grant') {
    if (!id) return {error: 'id or link required'};
    if (list.indexOf(id) === -1) list.push(id);
  } else if (req.op === 'ungrant') {
    list = list.filter(function (x) { return x !== id; });
  } else if (req.op !== 'grants') {
    return null;
  }
  if (req.op !== 'grants') {
    props.setProperty(key, JSON.stringify(list));
    CacheService.getScriptCache().remove('drv2:' + alias);
  }
  return {alias: alias, grants: list};
}

// ── Drive/Sheets helpers ────────────────────────────────────────────────────
function cleanId_(v) {
  v = String(v || '').trim();
  DRIVE_ID_RE.lastIndex = 0;
  var m = DRIVE_ID_RE.exec(v);
  if (m) return m[1];
  return /^[A-Za-z0-9_-]{20,}$/.test(v) ? v : '';
}

function fileMeta_(id) {
  var cache = CacheService.getScriptCache();
  var hit = cache.get('meta2:' + id);
  if (hit) return JSON.parse(hit);
  var meta = null;
  try {
    meta = api_(DRIVE + encodeURIComponent(id) + '?supportsAllDrives=true&fields=' + encodeURIComponent(FILE_FIELDS));
  } catch (e) { console.warn('drive metadata ' + id + ': ' + e.message); meta = null; }
  // Only successes are cached, so a passing API hiccup doesn't hide a file.
  if (meta) { try { cache.put('meta2:' + id, JSON.stringify(meta), 600); } catch (e) {} }
  return meta;
}

function brief_(f) {
  return {id: f.id, name: f.name, type: f.mimeType, modified: f.modifiedTime, link: f.webViewLink,
          owner: f.owners && f.owners[0] ? f.owners[0].emailAddress : ''};
}

function exportText_(id, mime) {
  var r = fetch_(DRIVE + encodeURIComponent(id) + '/export?mimeType=' + encodeURIComponent(mime));
  return r.getResponseCode() < 300 ? r.getContentText('UTF-8') : null;
}

function media_(id) {
  var r = fetch_(DRIVE + encodeURIComponent(id) + '?alt=media&supportsAllDrives=true');
  if (r.getResponseCode() >= 300) throw new Error('download failed (' + r.getResponseCode() + ')');
  return r.getBlob();
}

/** Every tab as CSV, each under a "## Sheet: <title>" heading. */
function sheetsCsv_(id) {
  var base = 'https://sheets.googleapis.com/v4/spreadsheets/' + encodeURIComponent(id);
  var sheets = (api_(base + '?fields=sheets.properties.title').sheets || []).map(function (s) { return s.properties.title; });
  if (!sheets.length) return '';
  var ranges = sheets.map(function (t) { return 'ranges=' + encodeURIComponent("'" + t.replace(/'/g, "''") + "'"); }).join('&');
  var vr = api_(base + '/values:batchGet?' + ranges + '&valueRenderOption=FORMATTED_VALUE').valueRanges || [];
  return vr.map(function (r, i) {
    var rows = (r.values || []).map(function (row) {
      return row.map(function (c) {
        c = String(c == null ? '' : c);
        return /[",\n]/.test(c) ? '"' + c.replace(/"/g, '""') + '"' : c;
      }).join(',');
    });
    return '## Sheet: ' + sheets[i] + '\n' + rows.join('\n');
  }).join('\n\n');
}

function fetch_(url) {
  return UrlFetchApp.fetch(url, {headers: {Authorization: 'Bearer ' + ScriptApp.getOAuthToken()}, muteHttpExceptions: true});
}

function api_(url) {
  var r = fetch_(url);
  if (r.getResponseCode() >= 300) throw new Error('Google API ' + r.getResponseCode() + ': ' + r.getContentText().slice(0, 200));
  return JSON.parse(r.getContentText());
}
