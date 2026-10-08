// =============================================================================
// collector.js - schema snapshot collector for betika_mongodb_normalized
//
// Executed by mongo_schema_normalizer.sh as:
//   mongosh --nodb --quiet --norc --file collector.js
// All parameters arrive through environment variables (credentials never go
// through argv, so they are not visible in `ps`). Mirror of python/bmn/collector.py.
//
// Environment:
//   BMN_MODE             collect (default) | ping
//   BMN_OUTPUT_FILE      snapshot path (collect mode)
//   BMN_INSTANCE_NAME, BMN_INSTANCE_ALIAS, BMN_INSTANCE_ROLE, BMN_CONF_FILE
//   BMN_BASE_URI         connection string without credentials
//   BMN_USER, BMN_PASSWORD, BMN_AUTH_SOURCE, BMN_READ_PREFERENCE
//   BMN_TLS, BMN_TLS_CA_FILE, BMN_TLS_CERT_KEY_FILE, BMN_TLS_ALLOW_INVALID_HOSTNAMES
//   BMN_TIMEOUT, BMN_OP_TIMEOUT (seconds), BMN_SAMPLE_SIZE, BMN_MAX_DEPTH
//   BMN_INCLUDE_DBS, BMN_EXCLUDE_DBS (regex), BMN_INCLUDE_SECURITY (1/0)
// Exit codes: 0 ok | 3 collection failed (an error snapshot is still written)
// =============================================================================
'use strict';

const fs = require('fs');

const TOOL_NAME = 'betika_mongodb_normalized';
const TOOL_VERSION = '1.0.0';
const SYSTEM_DBS = new Set(['admin', 'local', 'config']);
const MAX_ARRAY_ELEMENTS = 100;
const MAX_FIELD_PATHS = 1000;

const env = process.env;
const out = (msg) => (typeof print === 'function' ? print(msg) : console.log(msg));
const bmnExit = (code) => (typeof quit === 'function' ? quit(code) : process.exit(code));
const truthy = (v) => ['1', 'true', 'yes', 'on'].includes(String(v || '').trim().toLowerCase());
const intEnv = (name, def) => {
  const n = parseInt(env[name] || '', 10);
  return Number.isFinite(n) ? n : def;
};
const errText = (e) => `${(e && e.name) || 'Error'}: ${(e && e.message) || String(e)}`.split('\n')[0].slice(0, 500);
const isUnauthorized = (e) => {
  const text = String((e && e.message) || e).toLowerCase();
  return !!e && (e.code === 13 || e.codeName === 'Unauthorized' || text.includes('not authorized') || text.includes('unauthorized'));
};
// Short, actionable message for authorization failures (the raw one echoes the whole command).
const authErr = (e, privilege) => (isUnauthorized(e) ? `Unauthorized: missing privilege ${privilege}` : errText(e));
const PRIV_MEMBER = "'serverStatus' and 'top' actions on {cluster: true} (member stats)";
const PRIV_OPLOG = "'find' on {db: 'local', collection: 'oplog.rs'} (oplog window)";
const PRIV_SAMPLING = "'inprog' action on {cluster: true} ($currentOp with allUsers)";
const PRIV_USERS = "'viewUser' action on every database (session user resolution)";
const nowIso = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
const strcmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// BSON numeric wrappers (Long, Int32, Double, Decimal128) -> JS number.
function toNum(v) {
  if (typeof v === 'number') return v;
  if (v === null || v === undefined) return 0;
  if (typeof v.toNumber === 'function') return v.toNumber();
  if (typeof v.valueOf === 'function') {
    const x = Number(v.valueOf());
    if (Number.isFinite(x)) return x;
  }
  const x = Number(v);
  return Number.isFinite(x) ? x : 0;
}

// ------------------------------------------------------------------ connection string
function encodeParam(value) {
  return encodeURIComponent(value).replace(/%2F/gi, '/').replace(/%3A/gi, ':').replace(/%7E/gi, '~');
}

function buildUri() {
  const base = env.BMN_BASE_URI || '';
  const qpos = base.indexOf('?');
  let head = qpos >= 0 ? base.slice(0, qpos) : base;
  const query = qpos >= 0 ? base.slice(qpos + 1) : '';
  const schemeEnd = head.indexOf('://');
  if (schemeEnd < 0) throw new Error('invalid connection string (missing scheme)');
  if (!head.slice(schemeEnd + 3).includes('/')) head += '/';
  const params = query.split('&').filter(Boolean);
  const present = new Set(params.map((p) => p.split('=')[0].toLowerCase()));
  const add = (name, value) => {
    if (present.has(name.toLowerCase())) return;
    params.push(`${name}=${encodeParam(value)}`);
    present.add(name.toLowerCase());
  };
  const timeoutMs = String(intEnv('BMN_TIMEOUT', 15) * 1000);
  if (env.BMN_USER) add('authSource', env.BMN_AUTH_SOURCE || 'admin');
  add('readPreference', env.BMN_READ_PREFERENCE || 'secondaryPreferred');
  add('appName', TOOL_NAME);
  if (truthy(env.BMN_TLS) && !present.has('ssl')) add('tls', 'true');
  if (env.BMN_TLS_CA_FILE) add('tlsCAFile', env.BMN_TLS_CA_FILE);
  if (env.BMN_TLS_CERT_KEY_FILE) add('tlsCertificateKeyFile', env.BMN_TLS_CERT_KEY_FILE);
  if (truthy(env.BMN_TLS_ALLOW_INVALID_HOSTNAMES)) add('tlsAllowInvalidHostnames', 'true');
  add('serverSelectionTimeoutMS', timeoutMs);
  add('connectTimeoutMS', timeoutMs);
  return `${head}?${params.join('&')}`;
}

const redact = (uri) => uri.replace(/(:\/\/)[^@/]+@/, '$1***@');

function withCredentials(uri) {
  if (!env.BMN_USER) return uri;
  const idx = uri.indexOf('://') + 3;
  const authority = uri.slice(idx).split('/')[0];
  if (authority.includes('@')) return uri; // credentials already embedded (legacy MONGO_URI)
  const creds = `${encodeURIComponent(env.BMN_USER)}:${encodeURIComponent(env.BMN_PASSWORD || '')}@`;
  return uri.slice(0, idx) + creds + uri.slice(idx);
}

// ------------------------------------------------------------------ schema inference
const BSONTYPE_MAP = {
  ObjectId: 'objectId', ObjectID: 'objectId', Int32: 'int', Double: 'double', Long: 'long',
  Decimal128: 'decimal', Binary: 'binData', Timestamp: 'timestamp', BSONRegExp: 'regex', Code: 'javascript',
  MinKey: 'minKey', MaxKey: 'maxKey', DBRef: 'object', BSONSymbol: 'symbol', Symbol: 'symbol', UUID: 'binData',
};

function bsonType(v) {
  if (v === null) return 'null';
  if (v === undefined) return 'undefined';
  if (typeof v === 'boolean') return 'bool';
  if (typeof v === 'string') return 'string';
  // Only reached if promoteValues was not honored: width cannot be known exactly.
  if (typeof v === 'number') return Number.isInteger(v) ? 'int' : 'double';
  if (typeof v === 'bigint') return 'long';
  if (Array.isArray(v)) return 'array';
  if (v instanceof Date) return 'date';
  if (v instanceof RegExp) return 'regex';
  if (typeof Buffer !== 'undefined' && Buffer.isBuffer(v)) return 'binData';
  if (v._bsontype) return BSONTYPE_MAP[v._bsontype] || String(v._bsontype);
  return 'object';
}
const isPlainObject = (v) => bsonType(v) === 'object' && !(v && v._bsontype);

// BSON date/timestamp -> ISO-8601 UTC (seconds); null when invalid or outside years 1-9999 (same as Python).
function dateIso(v) {
  let d = null;
  if (v instanceof Date) d = v;
  else if (v && v._bsontype === 'Timestamp') d = new Date((typeof v.getHighBits === 'function' ? v.getHighBits() >>> 0 : v.t) * 1000);
  if (!d || !Number.isFinite(d.getTime())) return null;
  const year = d.getUTCFullYear();
  if (year < 1 || year > 9999) return null;
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function trackModified(p, t, value, modifiedRe, track) {
  if (!track || !modifiedRe || (t !== 'date' && t !== 'timestamp') || p.includes('[]')) return;
  if (!modifiedRe.test(p.split('.').pop())) return;
  const stamp = dateIso(value);
  if (stamp && (!(p in track) || stamp > track[p])) track[p] = stamp;
}

function walk(doc, prefix, depth, maxDepth, seen, modifiedRe, track) {
  for (const key of Object.keys(doc)) {
    const value = doc[key];
    const p = prefix ? `${prefix}.${key}` : key;
    const t = bsonType(value);
    seen.set(`${p}\u0000${t}`, [p, t]);
    trackModified(p, t, value, modifiedRe, track);
    if (t === 'object' && isPlainObject(value) && depth < maxDepth) {
      walk(value, p, depth + 1, maxDepth, seen, modifiedRe, track);
    } else if (t === 'array') {
      const ap = `${p}[]`;
      for (const elem of value.slice(0, MAX_ARRAY_ELEMENTS)) {
        const et = bsonType(elem);
        seen.set(`${ap}\u0000${et}`, [ap, et]);
        if (et === 'object' && isPlainObject(elem) && depth < maxDepth) walk(elem, ap, depth + 1, maxDepth, seen, modifiedRe, track);
      }
    }
  }
}

function inferSchema(docs, maxDepth, modifiedRe) {
  const fields = new Map();
  const modifiedMax = {};
  let truncated = false;
  for (const doc of docs) {
    const seen = new Map();
    walk(doc, '', 1, maxDepth, seen, modifiedRe || null, modifiedMax);
    const counted = new Set();
    for (const [p, t] of seen.values()) {
      if (!fields.has(p)) {
        if (fields.size >= MAX_FIELD_PATHS) {
          truncated = true;
          continue;
        }
        fields.set(p, { count: 0, types: {} });
      }
      const entry = fields.get(p);
      entry.types[t] = (entry.types[t] || 0) + 1;
      if (!counted.has(p)) {
        entry.count += 1;
        counted.add(p);
      }
    }
  }
  const ordered = {};
  for (const p of [...fields.keys()].sort(strcmp)) {
    const e = fields.get(p);
    const types = {};
    for (const t of Object.keys(e.types).sort(strcmp)) types[t] = e.types[t];
    ordered[p] = { count: e.count, types };
  }
  const modMax = {};
  for (const p of Object.keys(modifiedMax).sort(strcmp)) modMax[p] = modifiedMax[p];
  return { sampled: docs.length, truncated, fields: ordered, modified_max: modMax };
}

// ------------------------------------------------------------------ collection
function run(dbh, cmd) {
  const res = dbh.runCommand(cmd);
  if (!res || toNum(res.ok) !== 1) throw new Error(`${Object.keys(cmd)[0]} failed: ${res && (res.errmsg || res.codeName)}`);
  return res;
}

function collectHello(conn) {
  const admin = conn.getDB('admin');
  try {
    return run(admin, { hello: 1 });
  } catch (e) {
    return run(admin, { isMaster: 1 });
  }
}

function collectServer(conn) {
  const admin = conn.getDB('admin');
  const hello = collectHello(conn);
  const build = run(admin, { buildInfo: 1 });
  const server = { version: build.version, fcv: null, set_name: hello.setName || null, storage_engine: null };
  if (hello.msg === 'isdbgrid') server.topology = 'sharded';
  else if (hello.setName) server.topology = 'replicaset';
  else server.topology = 'standalone';
  try {
    const fcv = run(admin, { getParameter: 1, featureCompatibilityVersion: 1 });
    server.fcv = (fcv.featureCompatibilityVersion || {}).version || null;
  } catch (e) { /* not available on mongos / missing privilege */ }
  try {
    const st = run(admin, { serverStatus: 1, repl: 0, metrics: 0, locks: 0 });
    server.storage_engine = (st.storageEngine || {}).name || null;
  } catch (e) { /* missing clusterMonitor */ }
  return server;
}

// True if the user holds listDatabases on the cluster (otherwise only authorized DBs are listed).
function canListAll(conn) {
  let status;
  try {
    status = run(conn.getDB('admin'), { connectionStatus: 1, showPrivileges: true });
  } catch (e) {
    return null;
  }
  const auth = status.authInfo || {};
  if (!(auth.authenticatedUsers || []).length) return null; // no authentication: privileges are not reported
  for (const priv of auth.authenticatedUserPrivileges || []) {
    const res = priv.resource || {};
    if ((res.cluster || res.anyResource) && (priv.actions || []).includes('listDatabases')) return true;
  }
  return false;
}

function collectDb(conn, info, shardKeys, opts) {
  const dbh = conn.getDB(info.name);
  const out = { name: info.name, size_on_disk: toNum(info.sizeOnDisk), empty: !!info.empty, collections: [] };
  const infos = dbh.getCollectionInfos().slice().sort((a, b) => strcmp(a.name, b.name));
  for (const ci of infos) {
    const cname = ci.name;
    if (cname.startsWith('system.')) continue;
    const rawType = ci.type || 'collection';
    const ctype = rawType === 'view' || rawType === 'timeseries' ? rawType : 'collection';
    const coll = dbh.getCollection(cname);
    const entry = {
      name: cname, type: ctype, options: ci.options || {}, stats: null, stats_error: null, indexes: [],
      shard_key: null, shard_key_unique: false, schema: null, schema_error: null, activity: null,
    };
    const ns = `${info.name}.${cname}`;
    if (shardKeys[ns]) [entry.shard_key, entry.shard_key_unique] = shardKeys[ns];
    if (ctype !== 'view') {
      try {
        entry.indexes = coll.getIndexes().map((ix) => {
          const spec = {};
          for (const k of Object.keys(ix)) if (k !== 'v' && k !== 'ns') spec[k] = ix[k];
          return spec;
        }).sort((a, b) => strcmp(a.name || '', b.name || ''));
      } catch (e) {
        entry.stats_error = `listIndexes: ${errText(e)}`;
      }
      try {
        const total = { count: 0, size: 0, storage_size: 0, total_index_size: 0 };
        const docs = coll.aggregate([{ $collStats: { storageStats: {} } }], { maxTimeMS: opts.opTimeoutMs }).toArray();
        for (const d of docs) {
          const st = d.storageStats || {};
          total.count += toNum(st.count);
          total.size += toNum(st.size);
          total.storage_size += toNum(st.storageSize);
          total.total_index_size += toNum(st.totalIndexSize);
        }
        total.avg_obj_size = total.count ? Math.floor(total.size / total.count) : 0;
        entry.stats = total;
      } catch (e) {
        entry.stats_error = errText(e);
      }
      if (opts.activity.enabled && ctype === 'collection') {
        try {
          entry._id_bounds = idBounds(coll, opts.opTimeoutMs);
        } catch (e) {
          entry._id_bounds = { first_insert: null, last_insert: null, id_type: `error: ${errText(e)}` };
        }
      } else if (opts.activity.enabled) {
        entry._id_bounds = { first_insert: null, last_insert: null, id_type: 'n/a' };
      }
      if (opts.sampleSize > 0) {
        try {
          const docs = coll.aggregate([{ $sample: { size: opts.sampleSize } }],
            { maxTimeMS: opts.opTimeoutMs, promoteValues: false }).toArray();
          entry.schema = inferSchema(docs, opts.maxDepth, opts.activity.modifiedRe);
        } catch (e) {
          entry.schema_error = errText(e);
        }
      }
      if (opts.activity.enabled) entry._modified = modifiedDates(coll, entry.schema, entry.indexes, opts.activity, opts.opTimeoutMs);
    }
    out.collections.push(entry);
  }
  return out;
}

function collectSecurity(conn, dbNames) {
  const users = [];
  const roles = [];
  const errors = [];
  for (const name of dbNames) {
    const dbh = conn.getDB(name);
    try {
      for (const u of run(dbh, { usersInfo: 1 }).users || []) {
        users.push({ user: u.user, db: u.db, roles: (u.roles || []).map((r) => ({ role: r.role, db: r.db })) });
      }
    } catch (e) {
      errors.push(`usersInfo@${name}: ${errText(e)}`);
    }
    try {
      for (const r of run(dbh, { rolesInfo: 1, showPrivileges: true, showBuiltinRoles: false }).roles || []) {
        roles.push({ role: r.role, db: r.db, privileges: r.privileges || [], roles: (r.roles || []).map((x) => ({ role: x.role, db: x.db })) });
      }
    } catch (e) {
      errors.push(`rolesInfo@${name}: ${errText(e)}`);
    }
  }
  return { users, roles, errors };
}

// ------------------------------------------------------------------ activity
// Mirror of python/bmn/activity.py (see that module for the snapshot structures).
const NO_SESSION = '(no session)';
const NO_AUTH = '(no auth)';
const sleepMs = (ms) => (typeof sleep === 'function' ? sleep(ms) : Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms));
const isoOf = (v) => {
  if (v === null || v === undefined) return null;
  if (v._bsontype === 'Timestamp') v = tsSeconds(v);
  const d = typeof v === 'number' ? new Date(v * 1000) : v;
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
};
const isObjectId = (v) => !!v && (v._bsontype === 'ObjectId' || v._bsontype === 'ObjectID');
const tsSeconds = (ts) => {
  if (ts && typeof ts.getHighBits === 'function') return ts.getHighBits() >>> 0;
  if (ts && typeof ts.t === 'number') return ts.t;
  return EJSON.serialize({ v: ts }).v.$timestamp.t;
};
const makeTimestamp = (secs) => EJSON.deserialize({ v: { $timestamp: { t: secs, i: 0 } } }).v;
const uidHash = (name) => require('crypto').createHash('sha256').update(name, 'utf8').digest('hex');
const bump = (obj, key, n = 1) => { obj[key] = (obj[key] || 0) + n; };
const sortNested = (v) => {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return v;
  const out = {};
  for (const k of Object.keys(v).sort(strcmp)) out[k] = sortNested(v[k]);
  return out;
};

function memberUri(uri, host) {
  const qpos = uri.indexOf('?');
  const head = qpos >= 0 ? uri.slice(0, qpos) : uri;
  const query = qpos >= 0 ? uri.slice(qpos + 1) : '';
  const scheme = head.slice(0, head.indexOf('://'));
  const rest = head.slice(head.indexOf('://') + 3);
  const path = rest.includes('/') ? rest.slice(rest.indexOf('/') + 1) : '';
  const params = query.split('&').filter((p) => p && !['replicaset', 'directconnection'].includes(p.split('=')[0].toLowerCase()));
  const names = new Set(params.map((p) => p.split('=')[0].toLowerCase()));
  if (scheme === 'mongodb+srv' && !names.has('tls') && !names.has('ssl')) params.push('tls=true');
  params.push('directConnection=true');
  return `mongodb://${host}/${path}?${params.join('&')}`;
}

function idBounds(coll, timeoutMs) {
  const out = { first_insert: null, last_insert: null, id_type: 'empty' };
  const lo = coll.find({}, { _id: 1 }).sort({ _id: 1 }).limit(1).maxTimeMS(timeoutMs).toArray();
  if (!lo.length) return out;
  const hi = coll.find({}, { _id: 1 }).sort({ _id: -1 }).limit(1).maxTimeMS(timeoutMs).toArray();
  const loId = lo[0]._id;
  const hiId = hi.length ? hi[0]._id : null;
  const loOk = isObjectId(loId);
  const hiOk = isObjectId(hiId);
  if (loOk) out.first_insert = isoOf(loId.getTimestamp());
  if (hiOk) out.last_insert = isoOf(hiId.getTimestamp());
  out.id_type = loOk && hiOk ? 'objectId' : (loOk || hiOk ? 'mixed' : 'other');
  return out;
}

const oplogPipeline = (fromTs) => [
  { $match: { ts: { $gte: fromTs }, op: { $in: ['i', 'u', 'd', 'c'] } } },
  { $project: { ts: 1, uid: '$lsid.uid', entries: { $cond: [{ $isArray: '$o.applyOps' }, '$o.applyOps', [{ op: '$op', ns: '$ns', o: '$o' }]] } } },
  { $unwind: '$entries' },
  { $project: { ts: 1, uid: 1, op: '$entries.op', ns: '$entries.ns', cmd: { $cond: [{ $eq: ['$entries.op', 'c'] }, { $arrayElemAt: [{ $objectToArray: '$entries.o' }, 0] }, null] } } },
  { $group: { _id: { ns: '$ns', op: '$op', uid: '$uid', cmd: '$cmd.k', target: '$cmd.v' }, n: { $sum: 1 }, first: { $min: '$ts' }, last: { $max: '$ts' } } },
];

function resolveUid(uid, uidMap) {
  if (uid === null || uid === undefined) return NO_SESSION;
  const hex = uid._bsontype === 'Binary' ? uid.toString('hex') : Buffer.from(uid).toString('hex');
  return uidMap[hex] || `uid:${hex.slice(0, 12)}`;
}

const emptyOplogEntry = () => ({ inserts: 0, updates: 0, deletes: 0, commands: 0, first: null, last: null, created_at: null, users: {} });

function foldOplogRows(rows, uidMap) {
  const perNs = {};
  for (const row of rows) {
    const key = row._id || {};
    const op = key.op;
    let ns;
    if (op === 'i' || op === 'u' || op === 'd') {
      ns = key.ns || '';
    } else if (op === 'c') {
      if (typeof key.target !== 'string') continue;
      ns = key.cmd === 'renameCollection' ? key.target : `${(key.ns || '').split('.')[0]}.${key.target}`;
    } else {
      continue;
    }
    if (!ns || SYSTEM_DBS.has(ns.split('.')[0])) continue;
    if (!perNs[ns]) perNs[ns] = emptyOplogEntry();
    const e = perNs[ns];
    const n = toNum(row.n);
    e[{ i: 'inserts', u: 'updates', d: 'deletes', c: 'commands' }[op]] += n;
    const first = isoOf(row.first);
    const last = isoOf(row.last);
    if (first && (e.first === null || first < e.first)) e.first = first;
    if (last && (e.last === null || last > e.last)) e.last = last;
    if (op === 'c' && key.cmd === 'create' && last && (e.created_at === null || last > e.created_at)) e.created_at = last;
    bump(e.users, resolveUid(key.uid, uidMap), n);
  }
  for (const e of Object.values(perNs)) e.users = sortNested(e.users);
  return perNs;
}

function sampleOps(ops, sampled, users) {
  for (const op of ops) {
    const effective = op.effectiveUsers || [];
    if (!effective.length) continue; // internal operations (replication, TTL monitor...)
    const ns = op.ns || '';
    const dot = ns.indexOf('.');
    const db = dot >= 0 ? ns.slice(0, dot) : ns;
    let coll = dot >= 0 ? ns.slice(dot + 1) : '';
    if (!db || SYSTEM_DBS.has(db)) continue;
    if (!coll || coll === '$cmd') {
      const command = op.command || {};
      const keys = Object.keys(command);
      const first = keys.length ? command[keys[0]] : null;
      coll = typeof first === 'string' ? first : '';
    }
    const full = coll ? `${db}.${coll}` : db;
    const user = `${effective[0].user}@${effective[0].db}`;
    if (!sampled[full]) sampled[full] = { ops: 0, users: {} };
    sampled[full].ops += 1;
    bump(sampled[full].users, user);
    if (!users[user]) users[user] = { sampled_ops: 0, namespaces: {}, apps: {}, clients: {} };
    const u = users[user];
    u.sampled_ops += 1;
    bump(u.namespaces, full);
    if (op.appName) bump(u.apps, String(op.appName));
    if (op.client) {
      const c = String(op.client);
      bump(u.clients, c.includes(':') ? c.slice(0, c.lastIndexOf(':')) : c);
    }
  }
}

function collectActivity(conn, uri, hello, dbNames, aopts, opTimeoutMs) {
  const activity = { members: [], oplog: null, sampling: null, uid_map: null, users: {} };
  const hosts = (hello.hosts || []).concat(hello.passives || []);
  const members = [];
  const top = {};
  const starts = [];
  for (const host of (aopts.needsMembers ? (hosts.length ? hosts : [hello.me || 'self']) : [])) {
    const info = { host, state: null, started_at: null, error: null };
    try {
      const mc = hosts.length ? new Mongo(withCredentials(memberUri(uri, host))) : conn;
      const adm = mc.getDB('admin');
      const h = hosts.length ? run(adm, { hello: 1 }) : hello;
      info.state = (h.isWritablePrimary || h.ismaster) ? 'PRIMARY' : (h.secondary ? 'SECONDARY' : 'OTHER');
      if (aopts.memberStats) {
        const st = run(adm, { serverStatus: 1, repl: 0, metrics: 0, locks: 0 });
        info.started_at = isoOf(Math.floor(Date.now() / 1000) - Math.floor(toNum(st.uptime)));
        starts.push(info.started_at);
        const totals = run(adm, { top: 1 }).totals || {};
        for (const [ns, counters] of Object.entries(totals)) {
          if (ns === 'note' || !counters || typeof counters !== 'object') continue;
          const cnt = (k) => toNum((counters[k] || {}).count);
          if (!top[ns]) top[ns] = [0, 0];
          top[ns][0] += cnt('queries') + cnt('getmore');
          top[ns][1] += cnt('insert') + cnt('update') + cnt('remove');
        }
      }
      members.push([host, mc, info.state]);
    } catch (e) {
      info.error = authErr(e, PRIV_MEMBER);
    }
    activity.members.push(info);
  }
  const topSince = starts.length ? starts.slice().sort(strcmp)[starts.length - 1] : null;

  const uidMap = {};
  let oplogByNs = {};
  if (aopts.oplogHours > 0) {
    uidMap[uidHash('')] = NO_AUTH;
    let resolved = 0;
    let uidErr = null;
    for (const name of ['admin'].concat(dbNames)) {
      try {
        for (const u of run(conn.getDB(name), { usersInfo: 1 }).users || []) {
          uidMap[uidHash(`${u.user}@${u.db}`)] = `${u.user}@${u.db}`;
          resolved += 1;
        }
      } catch (e) {
        uidErr = uidErr || authErr(e, PRIV_USERS);
      }
    }
    activity.uid_map = { resolved, error: uidErr };
    const chosen = members.find((m) => m[2] === 'SECONDARY') || members[0] || null;
    const now = Math.floor(Date.now() / 1000);
    const olog = {
      member: chosen ? chosen[0] : null, window_hours: aopts.oplogHours,
      requested_from: isoOf(now - aopts.oplogHours * 3600), oplog_first: null, oplog_last: null, from: null, error: null,
    };
    try {
      if (!chosen) throw new Error('no reachable replica set member');
      const oplog = chosen[1].getDB('local').getCollection('oplog.rs');
      const first = oplog.find({}, { ts: 1 }).sort({ $natural: 1 }).limit(1).toArray();
      const last = oplog.find({}, { ts: 1 }).sort({ $natural: -1 }).limit(1).toArray();
      if (!first.length) throw new Error('oplog is empty or not readable');
      const firstSecs = tsSeconds(first[0].ts);
      olog.oplog_first = isoOf(firstSecs);
      olog.oplog_last = isoOf(tsSeconds(last[0].ts));
      const fromSecs = Math.max(now - aopts.oplogHours * 3600, firstSecs);
      olog.from = isoOf(fromSecs);
      const rows = oplog.aggregate(oplogPipeline(makeTimestamp(fromSecs)), { allowDiskUse: true, maxTimeMS: aopts.oplogTimeoutMs }).toArray();
      oplogByNs = foldOplogRows(rows, uidMap);
    } catch (e) {
      olog.error = authErr(e, PRIV_OPLOG);
    }
    activity.oplog = olog;
  }

  const sampled = {};
  if (aopts.samples > 0) {
    const samp = { samples: aopts.samples, interval_s: aopts.interval, members: members.length, started_at: isoOf(new Date()), finished_at: null, error: null };
    const pipeline = [
      { $currentOp: { allUsers: true, idleConnections: false } },
      { $match: { active: true, appName: { $ne: TOOL_NAME } } },
      { $project: { ns: 1, op: 1, command: 1, effectiveUsers: 1, appName: 1, client: 1 } },
    ];
    for (let rnd = 0; rnd < aopts.samples; rnd += 1) {
      for (const [host, mc] of members) {
        try {
          sampleOps(mc.getDB('admin').aggregate(pipeline, { maxTimeMS: opTimeoutMs }).toArray(), sampled, activity.users);
        } catch (e) {
          samp.error = samp.error || `${host}: ${authErr(e, PRIV_SAMPLING)}`;
        }
      }
      if (rnd < aopts.samples - 1) sleepMs(aopts.interval * 1000);
    }
    samp.finished_at = isoOf(new Date());
    activity.sampling = samp;
    activity.users = sortNested(activity.users);
  }
  for (const [, mc] of members) {
    if (mc !== conn) {
      try { mc.close(); } catch (e) { /* ignore */ }
    }
  }
  const sortedSampled = {};
  for (const [k, v] of Object.entries(sampled)) sortedSampled[k] = sortNested(v);
  return { activity, top, oplogByNs, topSince, sampled: sortedSampled };
}

const DATE_TYPES = ['date', 'timestamp'];
const getPath = (doc, p) => p.split('.').reduce((v, k) => (v && typeof v === 'object' && !Array.isArray(v) ? v[k] : undefined), doc);

function modifiedDates(coll, schema, indexes, aopts, timeoutMs) {
  const rx = aopts.modifiedRe;
  if (!rx) return [];
  const sch = schema || {};
  const lastSeg = (p) => p.split('.').pop();
  const candidates = {};
  for (const [p, info] of Object.entries(sch.fields || {})) {
    if (p.includes('[]') || !rx.test(lastSeg(p))) continue;
    candidates[p] = Object.keys(info.types || {}).filter((t) => t !== 'null' && t !== 'undefined').sort(strcmp);
  }
  const indexed = {};
  for (const ix of indexes || []) {
    if (ix.partialFilterExpression || ix.name === '_id_') continue;
    const keys = Object.entries(ix.key || {});
    if (keys.length && (keys[0][1] === 1 || keys[0][1] === -1) && !(keys[0][0] in indexed)) indexed[keys[0][0]] = ix.name;
  }
  for (const p of Object.keys(indexed)) {
    if (!p.includes('[]') && rx.test(lastSeg(p)) && !(p in candidates)) candidates[p] = [];
  }
  const sampleMax = sch.modified_max || {};
  const out = [];
  for (const p of Object.keys(candidates).sort(strcmp)) {
    const types = candidates[p];
    const entry = { path: p, types, method: 'none', index: null, value: null, error: null };
    if (types.length && !types.some((t) => DATE_TYPES.includes(t))) {
      entry.method = 'ignored';
      out.push(entry);
      continue;
    }
    // BSON order puts every Timestamp above every Date: take the max per type, then compare as instants.
    const latest = (values) => values.filter((x) => x).sort(strcmp).pop() || null;
    try {
      if (p in indexed) {
        entry.method = 'index';
        entry.index = indexed[p];
        const values = [];
        for (const btype of DATE_TYPES) {
          const docs = coll.find({ [p]: { $type: btype } }, { [p]: 1, _id: 0 }).sort({ [p]: -1 }).hint(indexed[p]).limit(1).maxTimeMS(timeoutMs).toArray();
          if (docs.length) values.push(dateIso(getPath(docs[0], p)));
        }
        entry.value = latest(values);
      } else if (aopts.modifiedScan) {
        entry.method = 'scan';
        const rows = coll.aggregate([{ $match: { [p]: { $type: DATE_TYPES } } }, { $group: { _id: { $type: `$${p}` }, m: { $max: `$${p}` } } }], { maxTimeMS: timeoutMs }).toArray();
        entry.value = latest(rows.map((r) => dateIso(r.m)));
      } else if (p in sampleMax) {
        entry.method = 'sample';
        entry.value = sampleMax[p];
      }
    } catch (e) {
      entry.error = errText(e);
    }
    out.push(entry);
  }
  return out;
}

function collectionActivity(ns, bounds, modified, ctx) {
  let best = null;
  for (const e of modified) if (e.value && (best === null || e.value > best.value)) best = e;
  const t = ctx.top[ns];
  const oplogOk = ctx.activity.oplog !== null && !ctx.activity.oplog.error;
  let topOut = null;
  if (t) topOut = { reads: t[0], writes: t[1], since: ctx.topSince };
  else if (ctx.topSince) topOut = { reads: 0, writes: 0, since: ctx.topSince };
  return {
    first_insert: bounds.first_insert === undefined ? null : bounds.first_insert,
    last_insert: bounds.last_insert === undefined ? null : bounds.last_insert,
    id_type: bounds.id_type === undefined ? null : bounds.id_type,
    modified,
    last_modified: best ? best.value : null,
    last_modified_field: best ? best.path : null,
    last_modified_method: best ? best.method : null,
    top: topOut,
    oplog: oplogOk ? (ctx.oplogByNs[ns] || emptyOplogEntry()) : null,
    sampled: ctx.activity.sampling ? (ctx.sampled[ns] || { ops: 0, users: {} }) : null,
  };
}

function writeSnapshot(file, snap) {
  const text = typeof EJSON !== 'undefined'
    ? EJSON.stringify(snap, null, 2, { relaxed: true })
    : JSON.stringify(snap, null, 2);
  fs.writeFileSync(file, `${text}\n`, 'utf8');
}

function main() {
  const mode = env.BMN_MODE || 'collect';
  let uri;
  try {
    uri = buildUri();
  } catch (e) {
    uri = '';
  }
  const opts = {
    sampleSize: intEnv('BMN_SAMPLE_SIZE', 100),
    maxDepth: intEnv('BMN_MAX_DEPTH', 5),
    opTimeoutMs: intEnv('BMN_OP_TIMEOUT', 120) * 1000,
    includeRe: env.BMN_INCLUDE_DBS ? new RegExp(env.BMN_INCLUDE_DBS) : null,
    excludeRe: env.BMN_EXCLUDE_DBS ? new RegExp(env.BMN_EXCLUDE_DBS) : null,
    security: truthy(env.BMN_INCLUDE_SECURITY),
    activity: {
      enabled: env.BMN_ACTIVITY === undefined ? true : truthy(env.BMN_ACTIVITY),
      oplogHours: intEnv('BMN_OPLOG_WINDOW', 0),
      oplogTimeoutMs: intEnv('BMN_OPLOG_TIMEOUT', 600) * 1000,
      samples: intEnv('BMN_ACTIVITY_SAMPLES', 0),
      interval: intEnv('BMN_ACTIVITY_INTERVAL', 10),
      memberStats: truthy(env.BMN_MEMBER_STATS),
      modifiedPattern: env.BMN_MODIFIED_PATTERN === undefined ? 'modif' : env.BMN_MODIFIED_PATTERN,
      modifiedScan: truthy(env.BMN_MODIFIED_SCAN),
    },
  };
  opts.activity.modifiedRe = opts.activity.modifiedPattern ? new RegExp(opts.activity.modifiedPattern, 'i') : null;
  opts.activity.needsMembers = opts.activity.memberStats || opts.activity.oplogHours > 0 || opts.activity.samples > 0;
  const snap = {
    tool: TOOL_NAME, tool_version: TOOL_VERSION, snapshot_format: 1, collector: 'bash',
    instance: {
      name: env.BMN_INSTANCE_NAME || 'unknown', alias: env.BMN_INSTANCE_ALIAS || env.BMN_INSTANCE_NAME || 'unknown',
      role: env.BMN_INSTANCE_ROLE || 'source', conf_file: env.BMN_CONF_FILE || '', uri: redact(uri),
    },
    collected_at: nowIso(), status: 'error', error: null,
    params: {
      sample_size: opts.sampleSize, max_depth: opts.maxDepth, activity: opts.activity.enabled,
      member_stats: opts.activity.memberStats, modified_pattern: opts.activity.modifiedPattern, modified_scan: opts.activity.modifiedScan,
      oplog_window_hours: opts.activity.oplogHours, activity_samples: opts.activity.samples, activity_interval_s: opts.activity.interval,
    },
    server: {}, databases: [], database_listing: null, security: null, activity: null,
  };

  let conn = null;
  try {
    if (!uri) throw new Error('invalid or missing connection string');
    conn = new Mongo(withCredentials(uri));
    if (mode === 'ping') {
      const build = run(conn.getDB('admin'), { buildInfo: 1 });
      out(`MongoDB ${build.version}`);
      return 0;
    }
    snap.server = collectServer(conn);
    const shardKeys = {};
    if (snap.server.topology === 'sharded') {
      for (const d of conn.getDB('config').getCollection('collections').find({ dropped: { $ne: true } }).toArray()) {
        shardKeys[d._id] = [d.key, !!d.unique];
      }
    }
    const listing = run(conn.getDB('admin'), { listDatabases: 1, nameOnly: false });
    const dbs = (listing.databases || []).slice().sort((a, b) => strcmp(a.name, b.name));
    const dbListing = { listed: [], system: [], excluded_by_filter: [], can_list_all: canListAll(conn) };
    for (const info of dbs) {
      dbListing.listed.push(info.name);
      if (SYSTEM_DBS.has(info.name)) {
        dbListing.system.push(info.name);
        continue;
      }
      if ((opts.includeRe && !opts.includeRe.test(info.name)) || (opts.excludeRe && opts.excludeRe.test(info.name))) {
        dbListing.excluded_by_filter.push(info.name);
        continue;
      }
      snap.databases.push(collectDb(conn, info, shardKeys, opts));
    }
    snap.database_listing = dbListing;
    if (opts.security) snap.security = collectSecurity(conn, ['admin'].concat(snap.databases.map((d) => d.name)));
    if (opts.activity.enabled) {
      const hello = collectHello(conn);
      const ctx = collectActivity(conn, uri, hello, snap.databases.map((d) => d.name), opts.activity, opts.opTimeoutMs);
      for (const d of snap.databases) {
        for (const c of d.collections) {
          const bounds = c._id_bounds || {};
          const modified = c._modified || [];
          delete c._id_bounds;
          delete c._modified;
          if (c.type === 'view') continue;
          c.activity = collectionActivity(`${d.name}.${c.name}`, bounds, modified, ctx);
        }
      }
      snap.activity = ctx.activity;
    }
    snap.status = 'ok';
  } catch (e) {
    snap.error = errText(e);
    if (mode === 'ping') {
      out(snap.error);
      return 3;
    }
  } finally {
    try { if (conn) conn.close(); } catch (e) { /* ignore */ }
  }
  writeSnapshot(env.BMN_OUTPUT_FILE, snap);
  return snap.status === 'ok' ? 0 : 3;
}

bmnExit(main());
