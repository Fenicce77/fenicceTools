// =============================================================================
// analyzer.js - offline analysis + artifact rendering for betika_mongodb_normalized
//
// Executed by mongo_schema_normalizer.sh through `mongosh --nodb --file` (or
// `node`). 1:1 port of python/bmn/{analyzer,renderers}.py: outputs must stay
// byte-identical (see tests/parity_check.sh).
//
// Input (environment):
//   BMN_SNAPSHOT_DIR, BMN_OUTPUT_DIR, BMN_TEMPLATES_DIR   (required)
//   BMN_NAMING_STRATEGY (auto|keep|prefix), BMN_PREFIX_SEP, BMN_TARGET,
//   BMN_MAPPING_FILE, BMN_GENERATED_AT, BMN_IMPLEMENTATION, NO_COLOR
// Exit codes: 0 ok | 1 blocking findings | 2 usage/input error
// =============================================================================
'use strict';

const fs = require('fs');
const path = require('path');

const TOOL_NAME = 'betika_mongodb_normalized';
const ANALYSIS_FORMAT = 1;
const NUMERIC_TYPES = new Set(['int', 'long', 'double', 'decimal']);
const NULLISH_TYPES = new Set(['null', 'undefined']);
const CONVERTIBLE_TYPES = new Set(['int', 'long', 'double', 'decimal', 'string', 'date', 'objectId']);
const INVALID_DB_CHARS = new Set(['/', '\\', '.', ' ', '"', '$', '\x00']);
const SEV_RANK = { ERROR: 0, WARN: 1, INFO: 2 };
const INDEX_SIG_OPTIONS = ['unique', 'sparse', 'hidden', 'partialFilterExpression', 'expireAfterSeconds', 'collation',
  'weights', 'default_language', 'language_override', 'wildcardProjection', 'bits', 'min', 'max', 'bucketSize'];
const INDEX_BOOL_OPTIONS = new Set(['unique', 'sparse', 'hidden']);
const INDEX_STRIP_KEYS = new Set(['v', 'ns', 'background', 'dropDups']);

const bmnExit = (code) => (typeof quit === 'function' ? quit(code) : process.exit(code));
const COLOR = !process.env.NO_COLOR;
const paint = (text, code) => (COLOR ? `\x1b[${code}m${text}\x1b[0m` : text);

// ------------------------------------------------------------------ helpers
const has = (obj, key) => obj !== null && typeof obj === 'object' && Object.prototype.hasOwnProperty.call(obj, key);
const strcmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const sortStr = (arr) => arr.slice().sort(strcmp);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const num = (v) => Math.trunc(Number(v || 0)) || 0;

function deepSort(v) {
  if (Array.isArray(v)) return v.map(deepSort);
  if (isObj(v)) {
    const out = {};
    for (const k of sortStr(Object.keys(v))) out[k] = deepSort(v[k]);
    return out;
  }
  return v;
}
const canon = (v, sortKeys = true) => JSON.stringify(sortKeys ? deepSort(v) : v);
const fmtValue = (v) => (v === undefined || v === null ? '-' : canon(v));
const dumpPretty = (v) => JSON.stringify(v, null, 2);
const md = (t) => String(t).split('|').join('\\|').split('\n').join(' ');
const shSingleQuote = (t) => `'${t.split("'").join("'\\''")}'`;
const replaceAll = (s, token, value) => s.split(token).join(value);

function parseVersion(v) {
  const m = /^(\d+)\.(\d+)(?:\.(\d+))?/.exec(String(v || ''));
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] || 0)] : [0, 0, 0];
}
function cmpVer(a, b, len = 3) {
  for (let i = 0; i < len; i += 1) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

function humanBytes(value) {
  let n = Number(value || 0);
  if (n < 1024) return `${Math.trunc(n)} B`;
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let idx = 0;
  while (n >= 1024 && idx < units.length - 1) {
    n /= 1024;
    idx += 1;
  }
  const rounded = Math.floor(n * 100 + 0.5) / 100;
  return `${rounded.toFixed(2)} ${units[idx]}`;
}

function indexSignature(ix) {
  const opts = {};
  let any = false;
  for (const key of INDEX_SIG_OPTIONS) {
    if (!has(ix, key)) continue;
    let val = ix[key];
    if (INDEX_BOOL_OPTIONS.has(key)) {
      if (!val) continue;
      val = true;
    }
    opts[key] = val;
    any = true;
  }
  let sig = canon(ix.key || {}, false);
  if (any) sig += ` ${canon(opts)}`;
  return sig;
}

function invalidDbName(name) {
  if (!name || Buffer.byteLength(name, 'utf8') >= 64) return true;
  for (const ch of name) if (INVALID_DB_CHARS.has(ch)) return true;
  return false;
}

function classifyTypes(types) {
  const nonNull = Object.keys(types).filter((t) => !NULLISH_TYPES.has(t));
  if (nonNull.length <= 1) return 'none';
  if (nonNull.every((t) => NUMERIC_TYPES.has(t))) return 'numeric';
  return 'mixed';
}
const byCountThenName = (a, b) => (b[1] - a[1]) || strcmp(a[0], b[0]);
const fmtTypes = (types) => Object.entries(types).sort(byCountThenName).map(([t, n]) => `${t}=${n}`).join(', ');

// ------------------------------------------------------------------ snapshot accessors
const sName = (s) => s.instance.name;
const sDbs = (s) => (s.databases || []).slice().sort((a, b) => strcmp(a.name, b.name));
const sColls = (d) => (d.collections || []).slice().sort((a, b) => strcmp(a.name, b.name));
const sStats = (c) => {
  const st = c.stats || {};
  return [num(st.count), num(st.size), num(st.storage_size), num(st.total_index_size)];
};
const sFields = (c) => (c.schema || {}).fields || {};
const emptyTotals = () => ({ databases: 0, collections: 0, views: 0, documents: 0, data_size: 0, storage_size: 0, index_size: 0 });

function totals(s) {
  const tot = emptyTotals();
  for (const d of sDbs(s)) {
    tot.databases += 1;
    for (const c of sColls(d)) {
      if (c.type === 'view') {
        tot.views += 1;
        continue;
      }
      tot.collections += 1;
      const [cnt, size, storage, idx] = sStats(c);
      tot.documents += cnt;
      tot.data_size += size;
      tot.storage_size += storage;
      tot.index_size += idx;
    }
  }
  return tot;
}

function instanceSummary(s, role) {
  const server = s.server || {};
  const ok = s.status === 'ok';
  return Object.assign({
    name: sName(s),
    alias: s.instance.alias || sName(s),
    role,
    status: s.status || 'error',
    error: s.error || null,
    uri: s.instance.uri || null,
    version: server.version || null,
    fcv: server.fcv || null,
    topology: server.topology || null,
  }, ok ? totals(s) : emptyTotals());
}

class Findings {
  constructor() { this.items = []; }

  add(severity, code, instance, namespace, message, details) {
    this.items.push({ severity, code, instance: instance || '', namespace: namespace || '', message, details: (details || []).slice() });
  }

  sorted() {
    return this.items.slice().sort((a, b) => (SEV_RANK[a.severity] - SEV_RANK[b.severity]) || strcmp(a.code, b.code)
      || strcmp(a.instance, b.instance) || strcmp(a.namespace, b.namespace) || strcmp(a.message, b.message));
  }
}

// ------------------------------------------------------------------ analysis
function analyze(snapshots, params) {
  const F = new Findings();
  const snaps = snapshots.slice().sort((a, b) => strcmp(sName(a), sName(b)));
  const byName = {};
  for (const s of snaps) byName[sName(s)] = s;

  let targetName = params.target || '';
  for (const s of snaps) {
    if (targetName && targetName === s.instance.alias && !has(byName, targetName)) {
      targetName = sName(s);
      break;
    }
  }
  if (!targetName) {
    const t = snaps.find((s) => s.instance.role === 'target');
    if (t) targetName = sName(t);
  }
  let target = null;
  if (targetName) {
    const cand = byName[targetName];
    if (!cand) F.add('ERROR', 'TARGET_NOT_FOUND', targetName, '', `target instance '${targetName}' has no snapshot`);
    else if (cand.status === 'ok') target = cand;
  }
  for (const s of snaps) {
    if (s.status !== 'ok') F.add('ERROR', 'COLLECT_ERROR', sName(s), '', `snapshot collection failed: ${s.error || 'unknown error'}`);
  }
  const sources = snaps.filter((s) => s.status === 'ok' && sName(s) !== targetName);
  const instances = snaps.map((s) => instanceSummary(s, sName(s) === targetName ? 'target' : 'source'));

  const tver = target ? parseVersion((target.server || {}).version) : [0, 0, 0];
  const tverStr = target ? ((target.server || {}).version || '') : '';
  const targetSharded = !!(target && (target.server || {}).topology === 'sharded');
  const targetDbs = {};
  if (target) for (const d of sDbs(target)) targetDbs[d.name] = new Set(sColls(d).map((c) => c.name));

  const dbInstances = {};
  for (const s of sources) for (const d of sDbs(s)) (dbInstances[d.name] = dbInstances[d.name] || []).push(sName(s));

  const lookup = (iname, alias, sdb) => {
    const m = params.mappings.find((e) => (e.instance === iname || e.instance === alias) && e.source_db === sdb);
    return m ? m.target_db : null;
  };

  const dbMapping = [];
  const nsMapping = [];
  const normalization = [];

  for (const s of sources) {
    const iname = sName(s);
    const alias = s.instance.alias || iname;
    for (const d of sDbs(s)) {
      const sdb = d.name;
      const mapped = lookup(iname, alias, sdb);
      let tdb;
      let reason;
      if (mapped !== null) [tdb, reason] = [mapped, 'mapping-file'];
      else if (params.naming_strategy === 'keep') [tdb, reason] = [sdb, 'keep'];
      else if (params.naming_strategy === 'prefix') [tdb, reason] = [`${alias}${params.prefix_sep}${sdb}`, 'prefix'];
      else if ((dbInstances[sdb] || []).length > 1) [tdb, reason] = [`${alias}${params.prefix_sep}${sdb}`, 'auto:source-conflict'];
      else if (has(targetDbs, sdb)) [tdb, reason] = [`${alias}${params.prefix_sep}${sdb}`, 'auto:target-conflict'];
      else [tdb, reason] = [sdb, 'keep'];

      const colls = sColls(d);
      const entry = { instance: iname, alias, source_db: sdb, target_db: tdb, reason, collections: 0, views: 0, documents: 0, data_size: 0, storage_size: 0, index_size: 0 };
      for (const c of colls) {
        if (c.type === 'view') {
          entry.views += 1;
          continue;
        }
        entry.collections += 1;
        const [cnt, size, storage, idx] = sStats(c);
        entry.documents += cnt;
        entry.data_size += size;
        entry.storage_size += storage;
        entry.index_size += idx;
      }
      dbMapping.push(entry);

      if (invalidDbName(tdb)) F.add('ERROR', 'DB_NAME_INVALID', iname, tdb, `target database name '${tdb}' is invalid (forbidden characters or >= 64 bytes)`);
      if (target && has(targetDbs, tdb)) F.add('WARN', 'TARGET_DB_EXISTS', iname, tdb, `target database '${tdb}' already exists on target '${targetName}'`);

      for (const c of colls) {
        const ctype = c.type || 'collection';
        const cname = c.name;
        const sns = `${sdb}.${cname}`;
        const tns = `${tdb}.${cname}`;
        const opts = c.options || {};
        const indexes = c.indexes || [];
        nsMapping.push({ instance: iname, source_ns: sns, target_ns: tns, type: ctype });

        if (Buffer.byteLength(tns, 'utf8') > 255) F.add('ERROR', 'NS_TOO_LONG', iname, sns, `target namespace '${tns}' exceeds 255 bytes`);
        if (target && has(targetDbs, tdb) && targetDbs[tdb].has(cname)) {
          F.add('ERROR', 'TARGET_NS_EXISTS', iname, sns, `target namespace '${tns}' already exists on target '${targetName}'`);
        }
        if (c.stats_error) F.add('WARN', 'STATS_ERROR', iname, sns, `$collStats failed: ${c.stats_error}`);
        if (c.schema_error) F.add('WARN', 'SAMPLE_ERROR', iname, sns, `schema sampling failed: ${c.schema_error}`);
        const schema = c.schema || {};
        if (schema.truncated) F.add('INFO', 'SCHEMA_TRUNCATED', iname, sns, 'field path limit reached while sampling (dynamic keys?); schema is partial');

        const mixed = [];
        const numeric = [];
        const fields = sFields(c);
        for (const p of sortStr(Object.keys(fields))) {
          const types = fields[p].types || {};
          const cls = classifyTypes(types);
          if (cls === 'none') continue;
          const line = `${p}: ${fmtTypes(types)}`;
          if (cls === 'numeric') {
            numeric.push(line);
            continue;
          }
          mixed.push(line);
          const nonNull = {};
          for (const [t, n] of Object.entries(types)) if (!NULLISH_TYPES.has(t)) nonNull[t] = n;
          if (p.includes('[]') || p.includes('$') || !Object.keys(nonNull).every((t) => CONVERTIBLE_TYPES.has(t))) continue;
          const dominant = Object.entries(nonNull).sort(byCountThenName)[0][0];
          const ordered = {};
          for (const t of sortStr(Object.keys(nonNull))) ordered[t] = nonNull[t];
          normalization.push({ instance: iname, source_ns: sns, target_ns: tns, db: tdb, collection: cname, path: p, dominant_type: dominant, types: ordered, sampled: num(schema.sampled) });
        }
        if (mixed.length) F.add('WARN', 'FIELD_TYPE_MIXED', iname, sns, `${mixed.length} field(s) with inconsistent BSON types in a sample of ${num(schema.sampled)} document(s)`, mixed);
        if (numeric.length) F.add('INFO', 'NUMERIC_TYPE_MIXED', iname, sns, `${numeric.length} field(s) mix numeric widths (int/long/double/decimal)`, numeric);

        const features = [];
        if (ctype === 'timeseries') features.push(['time-series collection', [5, 0]]);
        if (has(opts, 'clusteredIndex')) features.push(['clustered collection', [5, 3]]);
        if (has(opts, 'changeStreamPreAndPostImages')) features.push(['changeStreamPreAndPostImages', [6, 0]]);
        if (has(opts, 'encryptedFields')) features.push(['Queryable Encryption (encryptedFields)', [7, 0]]);
        for (const [label, req] of features) {
          if (target && cmpVer(tver, req, 2) < 0) {
            F.add('ERROR', 'FEATURE_UNSUPPORTED', iname, sns, `${label} requires MongoDB >= ${req[0]}.${req[1]}; target '${targetName}' runs ${tverStr}`);
          }
        }
        for (const ix of indexes) {
          if (Object.values(ix.key || {}).some((v) => v === 'geoHaystack')) {
            const sev = (!target || cmpVer(tver, [5, 0], 2) >= 0) ? 'ERROR' : 'WARN';
            F.add(sev, 'INDEX_TYPE_REMOVED', iname, sns, `geoHaystack index '${ix.name}' was removed in MongoDB 5.0; replace it with a 2d index and $geoWithin queries`);
          }
        }
        const legacy = [];
        for (const ix of indexes) for (const opt of ['background', 'dropDups']) if (has(ix, opt)) legacy.push(`${ix.name}: ${opt}`);
        if (legacy.length) F.add('INFO', 'INDEX_LEGACY_OPTION', iname, sns, `${legacy.length} legacy index option(s) will be stripped in bootstrap`, legacy);
        if (has(opts, 'autoIndexId')) F.add('WARN', 'OPTION_LEGACY', iname, sns, 'autoIndexId collection option is not supported by modern MongoDB and will be stripped');
        if (opts.capped) F.add('INFO', 'CAPPED', iname, sns, `capped collection (size=${fmtValue(opts.size)}, max=${fmtValue(opts.max)})`);
        const ttl = indexes.filter((ix) => has(ix, 'expireAfterSeconds') && !ix.clustered)
          .map((ix) => `${ix.name}: expireAfterSeconds=${fmtValue(ix.expireAfterSeconds)}`);
        if (ttl.length) F.add('INFO', 'TTL_INDEX', iname, sns, 'TTL index(es): expired documents are purged as soon as the index exists on target', ttl);
        if (ctype === 'view') F.add('INFO', 'VIEW', iname, sns, `view on '${opts.viewOn || '-'}' must be created after its source collections`);
        if (ctype === 'timeseries' && tdb !== sdb) {
          F.add('WARN', 'TIMESERIES_RENAME', iname, sns, 'time-series collection remapped to another database: validate mongorestore --nsFrom/--nsTo (system.buckets) on staging first');
        }
        if (c.shard_key) {
          if (targetSharded) {
            F.add('INFO', 'SHARD_KEY', iname, sns, `sharded on ${canon(c.shard_key, false)}; shardCollection is included in bootstrap`);
          } else {
            F.add('WARN', 'SHARD_KEY_LOST', iname, sns, `sharded on ${canon(c.shard_key, false)} but target is ${target ? 'not sharded' : 'undefined'}; the shard key will not be recreated`);
          }
        }
      }
    }
  }

  // --- collisions / merges
  const byTns = {};
  for (const e of nsMapping) (byTns[e.target_ns] = byTns[e.target_ns] || []).push(e);
  for (const tns of sortStr(Object.keys(byTns))) {
    const entries = byTns[tns];
    if (entries.length > 1) {
      F.add('ERROR', 'NS_COLLISION', sortStr([...new Set(entries.map((e) => e.instance))]).join(','), tns,
        'multiple source namespaces map to the same target namespace', sortStr(entries.map((e) => `${e.instance}:${e.source_ns}`)));
    }
  }
  const byTdb = {};
  for (const e of dbMapping) (byTdb[e.target_db] = byTdb[e.target_db] || []).push(e);
  for (const tdb of sortStr(Object.keys(byTdb))) {
    const entries = byTdb[tdb];
    if (entries.length > 1) {
      F.add('INFO', 'DB_MERGE', sortStr([...new Set(entries.map((e) => e.instance))]).join(','), tdb,
        'target database receives collections from multiple sources', sortStr(entries.map((e) => `${e.instance}:${e.source_db}`)));
    }
  }

  // --- versions
  if (target) {
    for (const s of sources) {
      const sv = (s.server || {}).version || '';
      if (cmpVer(parseVersion(sv), tver, 2) > 0) {
        F.add('WARN', 'VERSION_DOWNGRADE', sName(s), '', `source runs ${sv}, newer than target ${tverStr}; newer features/formats may not restore`);
      }
    }
  } else if (sources.length) {
    let best = sources[0];
    for (const s of sources.slice(1)) if (cmpVer(parseVersion(s.server.version), parseVersion(best.server.version)) > 0) best = s;
    const bv = parseVersion(best.server.version);
    F.add('INFO', 'NO_TARGET', '', '', `no target instance defined; the central instance should run MongoDB >= ${bv[0]}.${bv[1]}`);
  }
  const majors = new Set(sources.map((s) => parseVersion((s.server || {}).version).slice(0, 2).join('.')));
  if (majors.size > 1) {
    F.add('INFO', 'MIXED_VERSIONS', '', '', `source instances run ${majors.size} different major versions`,
      sortStr(sources.map((s) => `${sName(s)}: ${(s.server || {}).version}`)));
  }

  // --- drift across instances
  const groups = {};
  for (const s of sources) for (const d of sDbs(s)) for (const c of sColls(d)) {
    const ns = `${d.name}.${c.name}`;
    (groups[ns] = groups[ns] || []).push([sName(s), c]);
  }
  const drift = [];
  for (const ns of sortStr(Object.keys(groups))) {
    const members = groups[ns];
    if (members.length < 2) continue;
    const insts = members.map((m) => m[0]);
    const sigmap = {};
    for (const [iname, c] of members) {
      const sigs = {};
      for (const ix of c.indexes || []) {
        if (ix.name === '_id_' || ix.clustered) continue;
        sigs[indexSignature(ix)] = ix.name;
      }
      sigmap[iname] = sigs;
    }
    const allSigs = sortStr([...new Set([].concat(...Object.values(sigmap).map((x) => Object.keys(x))))]);
    const indexDiff = [];
    for (const sig of allSigs) {
      const present = insts.filter((i) => has(sigmap[i], sig));
      if (present.length === insts.length) continue;
      const names = {};
      for (const i of present) names[i] = sigmap[i][sig];
      indexDiff.push({ signature: sig, present_in: present, missing_in: insts.filter((i) => !has(sigmap[i], sig)), names });
    }
    const optCanon = {};
    for (const [iname, c] of members) optCanon[iname] = canon(c.options || {});
    const optionsEqual = new Set(Object.values(optCanon)).size === 1;
    const perPath = {};
    for (const [iname, c] of members) {
      for (const [p, f] of Object.entries(sFields(c))) {
        const ts = sortStr(Object.keys(f.types || {}).filter((t) => !NULLISH_TYPES.has(t)));
        if (ts.length) (perPath[p] = perPath[p] || {})[iname] = ts;
      }
    }
    const typeConflicts = [];
    for (const p of sortStr(Object.keys(perPath))) {
      const m = perPath[p];
      const vals = Object.values(m);
      if (vals.length < 2 || new Set(vals.map((v) => v.join('\u0000'))).size === 1) continue;
      const union = new Set([].concat(...vals));
      if ([...union].every((t) => NUMERIC_TYPES.has(t))) continue;
      const types = {};
      for (const i of insts) if (has(m, i)) types[i] = m[i];
      typeConflicts.push({ path: p, types });
    }
    drift.push({ namespace: ns, instances: insts, index_diff: indexDiff, options_equal: optionsEqual, options: optionsEqual ? {} : optCanon, type_conflicts: typeConflicts });
    const who = insts.join(',');
    if (indexDiff.length) {
      F.add('WARN', 'SCHEMA_DRIFT_INDEXES', who, ns, `${indexDiff.length} index definition(s) differ across instances`,
        indexDiff.map((d) => `${d.signature} present in [${d.present_in.join(',')}] missing in [${d.missing_in.join(',')}]`));
    }
    if (!optionsEqual) F.add('WARN', 'SCHEMA_DRIFT_OPTIONS', who, ns, 'collection options differ across instances', insts.map((i) => `${i}: ${optCanon[i]}`));
    if (typeConflicts.length) {
      F.add('WARN', 'SCHEMA_DRIFT_TYPES', who, ns, `${typeConflicts.length} field(s) with different BSON types across instances`,
        typeConflicts.map((t) => `${t.path}: ${Object.entries(t.types).map(([i, v]) => `${i}=[${v.join(',')}]`).join('; ')}`));
    }
  }

  const securityPlan = security(sources, dbMapping, F);

  const capacity = { per_instance: [], total: { documents: 0, data_size: 0, storage_size: 0, index_size: 0 }, target_existing: null };
  for (const s of sources) {
    const tot = totals(s);
    const row = { instance: sName(s), documents: tot.documents, data_size: tot.data_size, storage_size: tot.storage_size, index_size: tot.index_size };
    capacity.per_instance.push(row);
    for (const k of ['documents', 'data_size', 'storage_size', 'index_size']) capacity.total[k] += row[k];
  }
  if (target) {
    const tot = totals(target);
    capacity.target_existing = { documents: tot.documents, data_size: tot.data_size, storage_size: tot.storage_size, index_size: tot.index_size };
  }

  const findings = F.sorted();
  const byCode = {};
  for (const f of findings) byCode[f.code] = (byCode[f.code] || 0) + 1;
  const byCodeSorted = {};
  for (const k of sortStr(Object.keys(byCode))) byCodeSorted[k] = byCode[k];
  const summary = {
    errors: findings.filter((f) => f.severity === 'ERROR').length,
    warnings: findings.filter((f) => f.severity === 'WARN').length,
    info: findings.filter((f) => f.severity === 'INFO').length,
    by_code: byCodeSorted,
    sources: sources.length,
    source_databases: dbMapping.length,
    source_collections: nsMapping.filter((e) => e.type !== 'view').length,
    source_views: nsMapping.filter((e) => e.type === 'view').length,
    target_databases: new Set(dbMapping.map((e) => e.target_db)).size,
  };
  let targetInfo = null;
  if (target) {
    const srv = target.server || {};
    targetInfo = { name: targetName, version: srv.version || null, fcv: srv.fcv || null, topology: srv.topology || null };
  }
  return {
    tool: TOOL_NAME,
    analysis_format: ANALYSIS_FORMAT,
    implementation: params.implementation,
    generated_at: params.generated_at,
    params: { naming_strategy: params.naming_strategy, prefix_sep: params.prefix_sep, target: targetName || null, mapping_entries: params.mappings.length },
    target: targetInfo,
    instances,
    db_mapping: dbMapping,
    ns_mapping: nsMapping,
    drift,
    findings,
    normalization,
    security_plan: securityPlan,
    capacity,
    summary,
  };
}

function splitRole(ref) {
  const idx = ref.lastIndexOf('@');
  return { role: ref.slice(0, idx), db: ref.slice(idx + 1) };
}

function security(sources, dbMapping, F) {
  if (!sources.some((s) => s.security)) return null;
  const users = {};
  const roles = {};
  const mapDb = (dbmap, name) => (has(dbmap, name) ? dbmap[name] : name);
  for (const s of sources) {
    const sec = s.security;
    if (!sec) continue;
    const iname = sName(s);
    const dbmap = {};
    for (const e of dbMapping) if (e.instance === iname) dbmap[e.source_db] = e.target_db;
    const us = (sec.users || []).slice().sort((a, b) => strcmp(a.db || '', b.db || '') || strcmp(a.user || '', b.user || ''));
    for (const u of us) {
      const udb = mapDb(dbmap, u.db);
      const refs = sortStr([...new Set((u.roles || []).map((r) => `${r.role}@${mapDb(dbmap, r.db)}`))]);
      const key = `${u.user}@${udb}`;
      if (!has(users, key)) users[key] = { user: u.user, db: udb, by_source: {} };
      users[key].by_source[iname] = refs;
    }
    const rs = (sec.roles || []).slice().sort((a, b) => strcmp(a.db || '', b.db || '') || strcmp(a.role || '', b.role || ''));
    for (const r of rs) {
      const rdb = mapDb(dbmap, r.db);
      const privileges = (r.privileges || []).map((p) => {
        const res = Object.assign({}, p.resource || {});
        if (has(res, 'db') && has(dbmap, res.db)) res.db = dbmap[res.db];
        return { resource: res, actions: sortStr(p.actions || []) };
      });
      const inherited = sortStr([...new Set((r.roles || []).map((x) => `${x.role}@${mapDb(dbmap, x.db)}`))]);
      const key = `${r.role}@${rdb}`;
      if (!has(roles, key)) roles[key] = { role: r.role, db: rdb, by_source: {} };
      roles[key].by_source[iname] = { privileges, roles: inherited };
    }
  }
  const planUsers = [];
  for (const key of Object.keys(users).sort((a, b) => strcmp(users[a].db, users[b].db) || strcmp(users[a].user, users[b].user))) {
    const e = users[key];
    const srcs = sortStr(Object.keys(e.by_source));
    const variants = new Set(Object.values(e.by_source).map((v) => v.join('\u0000')));
    if (srcs.length > 1) {
      if (variants.size === 1) F.add('INFO', 'USER_DUPLICATE', srcs.join(','), key, 'same user and roles defined in several sources');
      else {
        F.add('WARN', 'USER_CONFLICT', srcs.join(','), key, 'user defined in several sources with different roles; bootstrap uses the union',
          srcs.map((i) => `${i}: ${e.by_source[i].join(',')}`));
      }
    }
    const union = sortStr([...new Set([].concat(...Object.values(e.by_source)))]);
    planUsers.push({ user: e.user, db: e.db, roles: union.map(splitRole), sources: srcs });
  }
  const planRoles = [];
  for (const key of Object.keys(roles).sort((a, b) => strcmp(roles[a].db, roles[b].db) || strcmp(roles[a].role, roles[b].role))) {
    const e = roles[key];
    const srcs = sortStr(Object.keys(e.by_source));
    const variants = new Set(Object.values(e.by_source).map((v) => canon(v)));
    if (srcs.length > 1) {
      if (variants.size === 1) F.add('INFO', 'ROLE_DUPLICATE', srcs.join(','), key, 'same custom role defined in several sources');
      else F.add('WARN', 'ROLE_CONFLICT', srcs.join(','), key, `custom role differs across sources; bootstrap uses the definition from '${srcs[0]}'`);
    }
    const chosen = e.by_source[srcs[0]];
    planRoles.push({ role: e.role, db: e.db, privileges: chosen.privileges, roles: chosen.roles.map(splitRole), sources: srcs });
  }
  return { users: planUsers, roles: planRoles };
}

// ------------------------------------------------------------------ renderers
const SEVERITY_TITLES = [['ERROR', 'Errors'], ['WARN', 'Warnings'], ['INFO', 'Informational']];

function findingLines(f) {
  const where = f.namespace ? ` \`${md(f.namespace)}\`` : '';
  const inst = f.instance ? ` (${md(f.instance)})` : '';
  return [`- **[${f.severity}] ${f.code}**${where}${inst}: ${md(f.message)}`].concat(f.details.map((d) => `  - \`${md(d)}\``));
}

function header(an, title) {
  const t = an.target;
  const target = t ? `\`${t.name}\` (MongoDB ${t.version}, ${t.topology})` : '_not defined_';
  const s = an.summary;
  return [
    `# ${title}`,
    '',
    `- Generated at: \`${an.generated_at}\` (${an.implementation} implementation)`,
    `- Naming strategy: \`${an.params.naming_strategy}\` (separator \`${an.params.prefix_sep}\`, mapping entries: ${an.params.mapping_entries})`,
    `- Target instance: ${target}`,
    `- Findings: **${s.errors}** errors, **${s.warnings}** warnings, **${s.info}** info`,
    '',
  ];
}

function renderReport(an, snapshots) {
  const L = header(an, 'MongoDB Schema Analysis Report');
  L.push('## 1. Instances', '',
    '| Instance | Alias | Role | Status | Version | FCV | Topology | DBs | Collections | Views | Documents | Data | Storage | Indexes |',
    '|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|');
  for (const i of an.instances) {
    L.push(`| ${md(i.name)} | ${md(i.alias)} | ${i.role} | ${i.status} | ${i.version || '-'} | ${i.fcv || '-'} | ${i.topology || '-'}`
      + ` | ${i.databases} | ${i.collections} | ${i.views} | ${i.documents} | ${humanBytes(i.data_size)}`
      + ` | ${humanBytes(i.storage_size)} | ${humanBytes(i.index_size)} |`);
  }
  L.push('', '## 2. Findings summary', '');
  if (an.findings.length) {
    L.push('| Severity | Code | Count |', '|---|---|---:|');
    const seen = {};
    const order = [];
    for (const f of an.findings) {
      const key = `${f.severity}|${f.code}`;
      if (!has(seen, key)) {
        order.push(key);
        seen[key] = 0;
      }
      seen[key] += 1;
    }
    for (const key of order) {
      const [sev, code] = key.split('|');
      L.push(`| ${sev} | ${code} | ${seen[key]} |`);
    }
  } else {
    L.push('_No findings._');
  }
  SEVERITY_TITLES.forEach(([sev, title], idx) => {
    L.push('', `## ${idx + 3}. ${title}`, '');
    const items = an.findings.filter((f) => f.severity === sev);
    if (!items.length) L.push('_None._');
    for (const f of items) L.push(...findingLines(f));
  });

  L.push('', '## 6. Inventory', '');
  for (const snap of snapshots.slice().sort((a, b) => strcmp(sName(a), sName(b)))) {
    L.push(`### Instance \`${sName(snap)}\``, '');
    if (snap.status !== 'ok') {
      L.push(`_Collection failed: ${md(snap.error || 'unknown error')}_`, '');
      continue;
    }
    const rows = [];
    for (const d of sDbs(snap)) {
      for (const c of sColls(d)) {
        const ctype = c.type || 'collection';
        const opts = c.options || {};
        const st = c.stats || {};
        const idx = c.indexes || [];
        const fields = sFields(c);
        const mixed = Object.values(fields).filter((f) => classifyTypes(f.types || {}) === 'mixed').length;
        if (ctype === 'view') {
          rows.push(`| ${md(d.name)} | ${md(c.name)} | view | - | - | - | - | - | - | - | - |`);
          continue;
        }
        rows.push(`| ${md(d.name)} | ${md(c.name)} | ${ctype} | ${num(st.count)}`
          + ` | ${humanBytes(st.size || 0)} | ${humanBytes(st.storage_size || 0)}`
          + ` | ${idx.length} | ${humanBytes(st.total_index_size || 0)}`
          + ` | ${opts.validator ? 'yes' : 'no'}`
          + ` | ${c.shard_key ? md(canon(c.shard_key, false)) : '-'} | ${mixed} |`);
      }
    }
    if (!rows.length) {
      L.push('_No user databases._', '');
      continue;
    }
    L.push('| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |',
      '|---|---|---|---:|---:|---:|---:|---:|---|---|---:|', ...rows, '');
  }

  L.push('## 7. Cross-instance comparison', '', '### 7.1 Database name overlap', '');
  const overlap = {};
  for (const e of an.db_mapping) (overlap[e.source_db] = overlap[e.source_db] || []).push(e.instance);
  const shared = sortStr(Object.keys(overlap)).filter((d) => overlap[d].length > 1);
  if (shared.length) {
    L.push('| Database | Instances |', '|---|---|', ...shared.map((d) => `| ${md(d)} | ${md(overlap[d].join(', '))} |`));
  } else {
    L.push('_No overlapping database names._');
  }
  L.push('', '### 7.2 Shared namespaces (drift)', '');
  if (!an.drift.length) L.push('_No namespaces shared across instances._');
  for (const d of an.drift) {
    L.push(`#### \`${md(d.namespace)}\` - ${md(d.instances.join(', '))}`, '');
    if (d.index_diff.length) {
      L.push(`- Indexes: **${d.index_diff.length} difference(s)**`);
      for (const x of d.index_diff) L.push(`  - \`${md(x.signature)}\` present in: ${x.present_in.join(', ')}; missing in: ${x.missing_in.join(', ')}`);
    } else {
      L.push('- Indexes: identical');
    }
    if (d.options_equal) {
      L.push('- Options: identical');
    } else {
      L.push('- Options: **differ**', ...Object.entries(d.options).map(([i, v]) => `  - ${md(i)}: \`${md(v)}\``));
    }
    if (d.type_conflicts.length) {
      L.push(`- Field types: **${d.type_conflicts.length} conflict(s)**`);
      for (const t of d.type_conflicts) {
        L.push(`  - \`${md(t.path)}\`: ${Object.entries(t.types).map(([i, v]) => `${i}=[${v.join(',')}]`).join('; ')}`);
      }
    } else {
      L.push('- Field types: consistent');
    }
    L.push('');
  }
  return `${L.join('\n').replace(/\n+$/, '')}\n`;
}

function renderPlan(an) {
  const s = an.summary;
  const L = header(an, 'MongoDB Centralization Plan');
  if (s.errors) L.push(`**Status: BLOCKED** - ${s.errors} blocking error(s) must be resolved before migrating.`);
  else L.push('**Status: READY** - no blocking errors (review the warnings).');
  L.push('', '## 1. Capacity', '', '| Instance | Documents | Data | Storage | Indexes |', '|---|---:|---:|---:|---:|');
  for (const r of an.capacity.per_instance) {
    L.push(`| ${md(r.instance)} | ${r.documents} | ${humanBytes(r.data_size)} | ${humanBytes(r.storage_size)} | ${humanBytes(r.index_size)} |`);
  }
  const t = an.capacity.total;
  L.push(`| **Total** | **${t.documents}** | **${humanBytes(t.data_size)}** | **${humanBytes(t.storage_size)}** | **${humanBytes(t.index_size)}** |`);
  const te = an.capacity.target_existing;
  if (te) {
    L.push('', `Target already holds ${te.documents} document(s), ${humanBytes(te.storage_size)} storage`
      + ` and ${humanBytes(te.index_size)} of indexes. Required free space (storage + indexes of`
      + ` sources, without compression gains): ${humanBytes(t.storage_size + t.index_size)}.`);
  }
  L.push('', '## 2. Database mapping', '',
    '| Instance | Source DB | Target DB | Reason | Collections | Views | Documents | Storage |',
    '|---|---|---|---|---:|---:|---:|---:|');
  for (const e of an.db_mapping) {
    L.push(`| ${md(e.instance)} | ${md(e.source_db)} | ${md(e.target_db)} | ${e.reason} | ${e.collections} | ${e.views} | ${e.documents} | ${humanBytes(e.storage_size)} |`);
  }
  if (!an.db_mapping.length) L.push('| - | - | - | - | 0 | 0 | 0 | 0 B |');

  L.push('', '## 3. Required modifications', '', '### 3.1 Blocking issues', '');
  const errs = an.findings.filter((f) => f.severity === 'ERROR');
  if (!errs.length) L.push('_None._');
  for (const f of errs) L.push(...findingLines(f));

  L.push('', '### 3.2 Database renames (application impact)', '');
  const renames = an.db_mapping.filter((e) => e.source_db !== e.target_db);
  if (!renames.length) L.push('_No database renames required._');
  for (const e of renames) {
    L.push(`- \`${md(e.instance)}\`: \`${md(e.source_db)}\` -> \`${md(e.target_db)}\` - update connection`
      + ' strings, application database names, and any cross-database $lookup/$merge/$out references.');
  }

  L.push('', '### 3.3 Index harmonization', '');
  const idxDrift = an.drift.filter((d) => d.index_diff.length);
  if (!idxDrift.length) L.push('_No index drift between instances._');
  for (const d of idxDrift) {
    L.push(`- \`${md(d.namespace)}\`: agree on a single index set before consolidating (${d.index_diff.length} difference(s)):`);
    for (const x of d.index_diff) L.push(`  - \`${md(x.signature)}\` only in ${x.present_in.join(', ')}`);
  }

  L.push('', '### 3.4 Data type normalization', '');
  if (!an.normalization.length) {
    L.push('_No scalar type normalization candidates._');
  } else {
    L.push('Candidates executed by `normalization_suggestions.js` (dry-run by default) after the data load:', '');
    for (const n of an.normalization) {
      const types = Object.entries(n.types).map(([k, v]) => `${k}=${v}`).join(', ');
      L.push(`- \`${md(n.target_ns)}\` field \`${md(n.path)}\` -> **${n.dominant_type}** (${types}; source ${md(n.instance)})`);
    }
  }

  L.push('', '### 3.5 Sharding', '');
  const shard = an.findings.filter((f) => f.code === 'SHARD_KEY' || f.code === 'SHARD_KEY_LOST');
  if (!shard.length) L.push('_No sharded source collections._');
  for (const f of shard) L.push(...findingLines(f));

  L.push('', '### 3.6 Security', '');
  const sp = an.security_plan;
  if (sp === null) {
    L.push('_Security objects not collected (run the collection with --include-security)._');
  } else {
    L.push(`${sp.users.length} user(s) and ${sp.roles.length} custom role(s) will be created by the`
      + ' `security` bootstrap phase (passwords are prompted, never exported).');
    for (const f of an.findings) if (f.code === 'USER_CONFLICT' || f.code === 'ROLE_CONFLICT') L.push(...findingLines(f));
  }

  L.push('', '## 4. Execution runbook', '',
    '1. Resolve every blocking issue and re-run the analysis until the status is READY.',
    '2. Create the database-tools YAML files referenced by `migration_commands.sh` (chmod 600).',
    '3. Freeze writes on the source databases: `mongodump` without `--oplog` is not point-in-time.',
    '4. `BMN_PHASE=collections mongosh <target> --file target_bootstrap.js` (dry-run), then with `BMN_APPLY=1`.',
    '5. `./migration_commands.sh --list`, then `./migration_commands.sh --apply`.',
    '6. `BMN_PHASE=indexes`, then `BMN_PHASE=views`, then `BMN_PHASE=security` with `BMN_APPLY=1`.',
    '7. Review and optionally apply `normalization_suggestions.js`.',
    '8. `BMN_PHASE=verify` to compare document counts, then switch application connection strings.',
    '', '## 5. Generated artifacts', '',
    '- `analysis.json`: machine-readable analysis (mapping, drift, findings).',
    '- `report.md`: inventory and cross-instance comparison.',
    '- `target_bootstrap.js`: idempotent mongosh bootstrap for the target (phased).',
    '- `migration_commands.sh`: mongodump/mongorestore jobs with namespace remapping.',
    '- `normalization_suggestions.js`: type normalization candidates.',
    '- `snapshots/`: raw per-instance schema snapshots (no document values).');
  return `${L.join('\n')}\n`;
}

function stripCollectionOptions(opts) {
  const out = {};
  for (const [k, v0] of Object.entries(opts)) {
    if (k === 'autoIndexId' || k === 'viewOn' || k === 'pipeline') continue;
    let v = v0;
    if (k === 'clusteredIndex' && isObj(v)) {
      v = {};
      for (const [kk, vv] of Object.entries(v0)) if (kk !== 'v') v[kk] = vv;
    }
    out[k] = v;
  }
  return out;
}

function buildBootstrapPlan(an, snapshots) {
  const tmap = {};
  for (const e of an.db_mapping) tmap[`${e.instance}\u0000${e.source_db}`] = e.target_db;
  const seen = new Set();
  const collections = [];
  const indexes = [];
  const views = [];
  for (const snap of snapshots.slice().sort((a, b) => strcmp(sName(a), sName(b)))) {
    const iname = sName(snap);
    for (const d of sDbs(snap)) {
      const key = `${iname}\u0000${d.name}`;
      if (!has(tmap, key)) continue;
      const tdb = tmap[key];
      for (const c of sColls(d)) {
        const tns = `${tdb}.${c.name}`;
        if (seen.has(tns)) continue;
        seen.add(tns);
        const src = `${iname}:${d.name}.${c.name}`;
        const opts = c.options || {};
        const ctype = c.type || 'collection';
        if (ctype === 'view') {
          const view = { db: tdb, name: c.name, viewOn: opts.viewOn === undefined ? null : opts.viewOn, pipeline: opts.pipeline || [] };
          if (opts.collation) view.collation = opts.collation;
          view.source = src;
          views.push(view);
          continue;
        }
        collections.push({
          db: tdb, name: c.name, type: ctype, options: stripCollectionOptions(opts),
          shard_key: c.shard_key || null, shard_unique: !!c.shard_key_unique,
          expected_documents: num((c.stats || {}).count), source: src,
        });
        const specs = (c.indexes || []).filter((ix) => ix.name !== '_id_' && !ix.clustered).map((ix) => {
          const spec = {};
          for (const [k, v] of Object.entries(ix)) if (!INDEX_STRIP_KEYS.has(k)) spec[k] = v;
          return spec;
        });
        if (specs.length) indexes.push({ db: tdb, collection: c.name, specs, source: src });
      }
    }
  }
  const sec = an.security_plan || { users: [], roles: [] };
  return {
    generated_at: an.generated_at,
    target: an.params.target,
    target_sharded: !!(an.target && an.target.topology === 'sharded'),
    collections, indexes, views, roles: sec.roles, users: sec.users,
  };
}

const readTemplate = (dir, name) => fs.readFileSync(path.join(dir, name), 'utf8');

function renderBootstrap(an, snapshots, tplDir) {
  let s = readTemplate(tplDir, 'bootstrap.js.tpl');
  s = replaceAll(s, '@@GENERATED_AT@@', an.generated_at);
  return replaceAll(s, '@@PLAN_JSON@@', dumpPretty(buildBootstrapPlan(an, snapshots)));
}

function renderNormalization(an, tplDir) {
  let s = readTemplate(tplDir, 'normalization.js.tpl');
  s = replaceAll(s, '@@GENERATED_AT@@', an.generated_at);
  return replaceAll(s, '@@FIXES_JSON@@', dumpPretty(an.normalization));
}

function renderMigration(an, tplDir) {
  const cfgLines = [];
  const seen = new Set();
  for (const i of an.instances) {
    if (i.role !== 'source' || i.status !== 'ok' || seen.has(i.alias)) continue;
    seen.add(i.alias);
    const v = `CFG_${i.alias.toUpperCase()}`;
    cfgLines.push(`# ${i.name}: ${i.uri || 'uri unknown'}`);
    cfgLines.push(`${v}="\${${v}:-\${BMN_TOOLS_CFG_DIR}/${i.alias}.yaml}"`);
  }
  const jobs = an.db_mapping.map((e) => `  ${shSingleQuote(`${e.alias}|${e.source_db}|${e.target_db}`)}`);
  let s = readTemplate(tplDir, 'migration_commands.sh.tpl');
  s = replaceAll(s, '@@GENERATED_AT@@', an.generated_at);
  s = replaceAll(s, '@@BLOCKING_ERRORS@@', String(an.summary.errors));
  s = replaceAll(s, '@@SOURCE_CONFIGS@@', cfgLines.length ? cfgLines.join('\n') : '# (no source instances)');
  return replaceAll(s, '@@JOBS@@', jobs.join('\n'));
}

// ------------------------------------------------------------------ io / main
function loadMappings(file) {
  if (!file) return [];
  const rx = /^([^:\s]+):([^=\s]+)=(\S+)$/;
  const entries = [];
  fs.readFileSync(file, 'utf8').split(/\r?\n/).forEach((raw, idx) => {
    const line = raw.split('#')[0].trim();
    if (!line) return;
    const m = rx.exec(line);
    if (!m) throw new Error(`${file}:${idx + 1}: expected '<instance>:<source_db>=<target_db>'`);
    entries.push({ instance: m[1], source_db: m[2], target_db: m[3] });
  });
  return entries;
}

function printSummary(an, outDir, files) {
  const s = an.summary;
  const tot = an.capacity.total;
  const status = s.errors ? paint('BLOCKED', '1;31') : paint('READY', '1;32');
  const lines = [
    paint('== Analysis summary ==', '1;36'),
    `  Sources: ${s.sources} | databases: ${s.source_databases} -> ${s.target_databases} | collections: ${s.source_collections} | views: ${s.source_views}`,
    `  Target : ${an.params.target || 'not defined'} | data to move: ${humanBytes(tot.storage_size + tot.index_size)} (storage + indexes)`,
    `  Findings: ${paint(`${s.errors} errors`, '31')}, ${paint(`${s.warnings} warnings`, '33')}, ${s.info} info`,
    `  Status : ${status}`,
    `  Output : ${outDir}`,
  ].concat(files.map((f) => `    - ${f}`));
  console.log(lines.join('\n'));
}

function main() {
  const env = process.env;
  const snapDir = env.BMN_SNAPSHOT_DIR;
  const outDir = env.BMN_OUTPUT_DIR;
  const tplDir = env.BMN_TEMPLATES_DIR;
  if (!snapDir || !outDir || !tplDir) {
    console.error('BMN_SNAPSHOT_DIR, BMN_OUTPUT_DIR and BMN_TEMPLATES_DIR are required');
    return 2;
  }
  const strategy = env.BMN_NAMING_STRATEGY || 'auto';
  if (!['auto', 'keep', 'prefix'].includes(strategy)) {
    console.error(`invalid naming strategy: ${strategy}`);
    return 2;
  }
  let files;
  let snapshots;
  let mappings;
  try {
    files = fs.readdirSync(snapDir).filter((f) => f.endsWith('.json')).sort(strcmp);
    if (!files.length) throw new Error(`no snapshots found in ${snapDir}`);
    snapshots = files.map((f) => JSON.parse(fs.readFileSync(path.join(snapDir, f), 'utf8')));
    mappings = loadMappings(env.BMN_MAPPING_FILE || '');
  } catch (e) {
    console.error(`input error: ${e.message}`);
    return 2;
  }
  const an = analyze(snapshots, {
    naming_strategy: strategy,
    prefix_sep: env.BMN_PREFIX_SEP === undefined ? '_' : env.BMN_PREFIX_SEP,
    target: env.BMN_TARGET || '',
    mappings,
    generated_at: env.BMN_GENERATED_AT || new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    implementation: env.BMN_IMPLEMENTATION || 'bash',
  });
  fs.mkdirSync(outDir, { recursive: true });
  const artifacts = [
    ['analysis.json', `${dumpPretty(an)}\n`],
    ['report.md', renderReport(an, snapshots)],
    ['centralization_plan.md', renderPlan(an)],
    ['target_bootstrap.js', renderBootstrap(an, snapshots, tplDir)],
    ['migration_commands.sh', renderMigration(an, tplDir)],
    ['normalization_suggestions.js', renderNormalization(an, tplDir)],
  ];
  for (const [name, content] of artifacts) {
    const p = path.join(outDir, name);
    fs.writeFileSync(p, content, 'utf8');
    if (name.endsWith('.sh')) fs.chmodSync(p, 0o750);
  }
  printSummary(an, outDir, artifacts.map((a) => a[0]));
  return an.summary.errors ? 1 : 0;
}

bmnExit(main());
