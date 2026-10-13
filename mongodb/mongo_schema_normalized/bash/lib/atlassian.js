// =============================================================================
// atlassian.js - JSON helper for the bash publisher (lib/publish.sh).
//
// Builds Jira / Confluence Data Center REST payloads and parses responses so
// the bash implementation needs neither jq nor python. Mirror of the payload
// functions in python/bmn/publish.py. Executed with `mongosh --nodb --file` or
// `node`; every parameter arrives through environment variables.
//
// Modes (BMN_ATL_MODE):
//   jira-create | jira-update  BMN_ANALYSIS, BMN_DESC_FILE, BMN_OUT, BMN_JIRA_* -> payload file;
//                              prints SUMMARY=, ISSUETYPE=, CHARS= lines
//   jira-comment               BMN_DESC_FILE, BMN_OUT, BMN_JIRA_COMMENT_VISIBILITY -> payload file;
//                              prints CHARS=, VIS= lines (exit 3 + message on invalid visibility)
//   confluence                 BMN_ANALYSIS, BMN_BODY_FILE, BMN_OUT, BMN_TITLE, BMN_SPACE,
//                              BMN_PARENT_ID, BMN_PAGE_ID, BMN_PAGE_VERSION -> payload file; prints CHARS=
//   confluence-query           BMN_SPACE, BMN_TITLE -> prints the search query string
//   confluence-page            BMN_IN (search response) -> prints "<id> <version>" or nothing
//   get                        BMN_IN (JSON file), BMN_FIELD (dotted path) -> prints the value
//   error                      BMN_IN (response file), BMN_CODE -> prints a readable API error
//   state-get                  BMN_STATE, BMN_FIELD -> prints the value stored in publish.json
//   state-set                  BMN_STATE, BMN_PRODUCT (jira|jira_comment|confluence), BMN_R_* fields, BMN_ANALYSIS -> publish.json
// =============================================================================
'use strict';

const fs = require('fs');

const TOOL_NAME = 'betika_mongodb_normalized';
const DEFAULT_TITLE = 'MongoDB schema centralization analysis';
const env = process.env;
const out = (msg) => (typeof print === 'function' ? print(msg) : console.log(msg));
const bmnExit = (code) => (typeof quit === 'function' ? quit(code) : process.exit(code));
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const splitList = (value) => String(value || '').split(',').map((x) => x.trim()).filter((x) => x);
const codePoints = (text) => [...text].length; // same as Python len()

function dig(obj, path) {
  let cur = obj;
  for (const part of String(path).split('.')) {
    if (cur === null || cur === undefined) return undefined;
    cur = Array.isArray(cur) ? cur[Number(part)] : cur[part];
  }
  return cur;
}

function jiraSummary(an) {
  if (env.BMN_JIRA_SUMMARY) return env.BMN_JIRA_SUMMARY;
  const s = an.summary;
  const status = s.errors ? 'BLOCKED' : 'READY';
  return `${DEFAULT_TITLE} - ${status} (${s.errors} errors, ${s.warnings} warnings) - ${an.generated_at.slice(0, 10)}`;
}

function apiError(code, data) {
  if (data && typeof data === 'object' && !Array.isArray(data)) {
    const parts = (data.errorMessages || []).slice();
    for (const k of Object.keys(data.errors || {}).sort()) parts.push(`${k}: ${data.errors[k]}`);
    if (data.message) parts.push(String(data.message));
    if (parts.length) return `HTTP ${code}: ${parts.join('; ')}`;
  }
  const text = data === null || data === undefined || data === '' ? 'no response body' : String(typeof data === 'string' ? data : JSON.stringify(data)).slice(0, 300);
  return `HTTP ${code}: ${text}`;
}

function main() {
  const mode = env.BMN_ATL_MODE || '';
  if (mode === 'jira-create' || mode === 'jira-update') {
    const an = readJson(env.BMN_ANALYSIS);
    const description = fs.readFileSync(env.BMN_DESC_FILE, 'utf8');
    let payload;
    const issuetype = env.BMN_JIRA_ISSUE_TYPE || 'Task';
    if (mode === 'jira-create') {
      const fields = {
        project: { key: env.BMN_JIRA_PROJECT || '' },
        issuetype: { name: issuetype },
        summary: jiraSummary(an),
        description,
        labels: splitList(env.BMN_JIRA_LABELS || 'mongodb,schema-centralization'),
      };
      const components = splitList(env.BMN_JIRA_COMPONENTS);
      if (components.length) fields.components = components.map((c) => ({ name: c }));
      payload = { fields };
    } else {
      payload = { fields: { summary: jiraSummary(an), description } };
    }
    fs.writeFileSync(env.BMN_OUT, JSON.stringify(payload), 'utf8');
    out(`SUMMARY=${jiraSummary(an)}`);
    out(`ISSUETYPE=${issuetype}`);
    out(`CHARS=${codePoints(description)}`);
    return 0;
  }
  if (mode === 'jira-comment') {
    const body = fs.readFileSync(env.BMN_DESC_FILE, 'utf8');
    const payload = { body };
    const vis = String(env.BMN_JIRA_COMMENT_VISIBILITY || '').trim();
    let visText = '';
    if (vis) {
      const idx = vis.indexOf(':');
      const kind = (idx >= 0 ? vis.slice(0, idx) : vis).trim();
      const value = idx >= 0 ? vis.slice(idx + 1).trim() : '';
      if (!['role', 'group'].includes(kind) || !value) {
        out(`JIRA_COMMENT_VISIBILITY must be 'role:<name>' or 'group:<name>' (got '${vis}')`);
        return 3;
      }
      payload.visibility = { type: kind, value };
      visText = `, visible to ${kind} ${value}`;
    }
    fs.writeFileSync(env.BMN_OUT, JSON.stringify(payload), 'utf8');
    out(`CHARS=${codePoints(body)}`);
    out(`VIS=${visText}`);
    return 0;
  }
  if (mode === 'confluence') {
    const an = readJson(env.BMN_ANALYSIS);
    const body = fs.readFileSync(env.BMN_BODY_FILE, 'utf8');
    const payload = { type: 'page', title: env.BMN_TITLE, space: { key: env.BMN_SPACE || '' }, body: { storage: { value: body, representation: 'storage' } } };
    if (!env.BMN_PAGE_ID) {
      if (env.BMN_PARENT_ID) payload.ancestors = [{ id: env.BMN_PARENT_ID }];
    } else {
      payload.id = env.BMN_PAGE_ID;
      payload.version = { number: parseInt(env.BMN_PAGE_VERSION, 10) + 1, message: `${TOOL_NAME} analysis ${an.generated_at}` };
    }
    fs.writeFileSync(env.BMN_OUT, JSON.stringify(payload), 'utf8');
    out(`CHARS=${codePoints(body)}`);
    return 0;
  }
  if (mode === 'confluence-query') {
    const q = new URLSearchParams({ spaceKey: env.BMN_SPACE || '', title: env.BMN_TITLE || '', type: 'page', expand: 'version' });
    out(q.toString());
    return 0;
  }
  if (mode === 'confluence-page') {
    const data = readJson(env.BMN_IN);
    const first = (data.results || [])[0];
    if (first) out(`${first.id} ${parseInt(dig(first, 'version.number'), 10) || 1}`);
    return 0;
  }
  if (mode === 'get') {
    let data = null;
    try {
      data = readJson(env.BMN_IN);
    } catch (e) {
      return 0;
    }
    const v = dig(data, env.BMN_FIELD);
    if (v !== undefined && v !== null) out(typeof v === 'object' ? JSON.stringify(v) : String(v));
    return 0;
  }
  if (mode === 'error') {
    let data = null;
    try {
      const raw = fs.readFileSync(env.BMN_IN, 'utf8');
      try {
        data = raw ? JSON.parse(raw) : null;
      } catch (e) {
        data = raw.slice(0, 300);
      }
    } catch (e) {
      data = null;
    }
    out(apiError(env.BMN_CODE, data));
    return 0;
  }
  if (mode === 'state-get') {
    if (!fs.existsSync(env.BMN_STATE)) return 0;
    let data;
    try {
      data = readJson(env.BMN_STATE);
    } catch (e) {
      return 0;
    }
    const v = dig(data, env.BMN_FIELD);
    if (v !== undefined && v !== null) out(String(v));
    return 0;
  }
  if (mode === 'state-set') {
    let state = {};
    if (fs.existsSync(env.BMN_STATE)) {
      try {
        state = readJson(env.BMN_STATE);
      } catch (e) {
        state = {};
      }
    }
    const orNull = (v) => (v === undefined || v === '' ? null : v);
    if (env.BMN_PRODUCT === 'jira_comment') {
      state.jira_comment = { issue: orNull(env.BMN_R_ISSUE), comment_id: orNull(env.BMN_R_COMMENT_ID), url: orNull(env.BMN_R_URL), attachments: splitList(env.BMN_R_ATTACHMENTS) };
    } else if (env.BMN_PRODUCT === 'jira') {
      state.jira = { issue: orNull(env.BMN_R_ISSUE), action: orNull(env.BMN_R_ACTION), url: orNull(env.BMN_R_URL), attachments: splitList(env.BMN_R_ATTACHMENTS) };
    } else {
      state.confluence = {
        page_id: orNull(env.BMN_R_PAGE_ID), title: orNull(env.BMN_R_TITLE), action: orNull(env.BMN_R_ACTION),
        version: env.BMN_R_VERSION ? parseInt(env.BMN_R_VERSION, 10) : null, url: orNull(env.BMN_R_URL),
      };
    }
    state.published_at_analysis = readJson(env.BMN_ANALYSIS).generated_at;
    fs.writeFileSync(env.BMN_STATE, `${JSON.stringify(state, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
    fs.chmodSync(env.BMN_STATE, 0o600);
    return 0;
  }
  out(`unknown BMN_ATL_MODE: ${mode}`);
  return 2;
}

bmnExit(main());
