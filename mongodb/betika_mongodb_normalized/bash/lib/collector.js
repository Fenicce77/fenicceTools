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

function walk(doc, prefix, depth, maxDepth, seen) {
  for (const key of Object.keys(doc)) {
    const value = doc[key];
    const p = prefix ? `${prefix}.${key}` : key;
    const t = bsonType(value);
    seen.set(`${p}\u0000${t}`, [p, t]);
    if (t === 'object' && isPlainObject(value) && depth < maxDepth) {
      walk(value, p, depth + 1, maxDepth, seen);
    } else if (t === 'array') {
      const ap = `${p}[]`;
      for (const elem of value.slice(0, MAX_ARRAY_ELEMENTS)) {
        const et = bsonType(elem);
        seen.set(`${ap}\u0000${et}`, [ap, et]);
        if (et === 'object' && isPlainObject(elem) && depth < maxDepth) walk(elem, ap, depth + 1, maxDepth, seen);
      }
    }
  }
}

function inferSchema(docs, maxDepth) {
  const fields = new Map();
  let truncated = false;
  for (const doc of docs) {
    const seen = new Map();
    walk(doc, '', 1, maxDepth, seen);
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
  return { sampled: docs.length, truncated, fields: ordered };
}

// ------------------------------------------------------------------ collection
function run(dbh, cmd) {
  const res = dbh.runCommand(cmd);
  if (!res || toNum(res.ok) !== 1) throw new Error(`${Object.keys(cmd)[0]} failed: ${res && (res.errmsg || res.codeName)}`);
  return res;
}

function collectServer(conn) {
  const admin = conn.getDB('admin');
  let hello;
  try {
    hello = run(admin, { hello: 1 });
  } catch (e) {
    hello = run(admin, { isMaster: 1 });
  }
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
      shard_key: null, shard_key_unique: false, schema: null, schema_error: null,
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
      if (opts.sampleSize > 0) {
        try {
          const docs = coll.aggregate([{ $sample: { size: opts.sampleSize } }],
            { maxTimeMS: opts.opTimeoutMs, promoteValues: false }).toArray();
          entry.schema = inferSchema(docs, opts.maxDepth);
        } catch (e) {
          entry.schema_error = errText(e);
        }
      }
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
  };
  const snap = {
    tool: TOOL_NAME, tool_version: TOOL_VERSION, snapshot_format: 1, collector: 'bash',
    instance: {
      name: env.BMN_INSTANCE_NAME || 'unknown', alias: env.BMN_INSTANCE_ALIAS || env.BMN_INSTANCE_NAME || 'unknown',
      role: env.BMN_INSTANCE_ROLE || 'source', conf_file: env.BMN_CONF_FILE || '', uri: redact(uri),
    },
    collected_at: nowIso(), status: 'error', error: null,
    params: { sample_size: opts.sampleSize, max_depth: opts.maxDepth },
    server: {}, databases: [], security: null,
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
    for (const info of dbs) {
      if (SYSTEM_DBS.has(info.name)) continue;
      if (opts.includeRe && !opts.includeRe.test(info.name)) continue;
      if (opts.excludeRe && opts.excludeRe.test(info.name)) continue;
      snap.databases.push(collectDb(conn, info, shardKeys, opts));
    }
    if (opts.security) snap.security = collectSecurity(conn, ['admin'].concat(snap.databases.map((d) => d.name)));
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
