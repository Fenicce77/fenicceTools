/**
 * Script: mongo_list_users.js
 * Description: Audits MongoDB users: authentication database, SCRAM mechanisms, direct
 *              and inherited roles, and an abbreviated access summary per database
 *              (RO / RW / ALL, +ADM_DB / +ADM_USR) with short tags for system roles (ROOT, MON, ...).
 * Compatibility: mongosh 1.x/2.x and the legacy mongo shell 4.x, against MongoDB 4.0 - 8.x.
 *              Written in ES5 on purpose so the legacy shell's SpiderMonkey engine can
 *              parse it. Shell API calls are kept out of array callbacks (mongosh
 *              async-rewriter limitation).
 *
 * Arguments (first match wins):
 *   1. MONGO_EXEC_CTX.args  - set by sh/mongo_exec.sh (-a <arg>).
 *   2. MONGO_SCRIPT_ARGS     - environment variable, mongosh only.
 *                              e.g. MONGO_SCRIPT_ARGS="--json --user=rmateos" mongosh ... --file x.js
 *
 * Exit codes: 0 ok, 1 server/command error, 2 usage error.
 */
(function () {
  var SCRIPT_VERSION = "2.2.0";

  // --- Runtime detection --------------------------------------------------------
  var CTX = (typeof MONGO_EXEC_CTX !== "undefined" && MONGO_EXEC_CTX) ? MONGO_EXEC_CTX : null;
  var HAS_PROCESS = (typeof process !== "undefined" && process && process.env);
  // mongosh runs on Node (process is defined); the legacy shell has no process and no
  // stderr writer, so messages go through print() there.
  var HAS_CONSOLE = !!(HAS_PROCESS && process.versions && typeof console !== "undefined" &&
    typeof console.error === "function");

  function useColor() {
    if (CTX && typeof CTX.color === "boolean") { return CTX.color; }
    if (HAS_PROCESS) {
      return !!(process.stdout && process.stdout.isTTY) && !process.env.NO_COLOR;
    }
    return false;
  }

  var C = { reset: "", bold: "", cyan: "", green: "", yellow: "", red: "", magenta: "", gray: "" };

  function setColors(enabled) {
    var on = {
      reset: "\x1b[0m", bold: "\x1b[1m", cyan: "\x1b[36m", green: "\x1b[32m",
      yellow: "\x1b[33m", red: "\x1b[31m", magenta: "\x1b[35m", gray: "\x1b[90m"
    };
    for (var k in on) {
      if (on.hasOwnProperty(k)) { C[k] = enabled ? on[k] : ""; }
    }
  }

  function out(msg) { print(msg); }

  function err(msg) {
    if (HAS_CONSOLE) { console.error(msg); } else { print(msg); }
  }

  function fail(code, msg) {
    err(C.red + "[ERROR]" + C.reset + " " + msg);
    quit(code);
  }

  function warn(msg) {
    err(C.yellow + "[WARN]" + C.reset + " " + msg);
  }

  // --- Help -----------------------------------------------------------------------
  function printHelp() {
    var lines = [
      "",
      C.bold + C.cyan + "mongo_list_users.js " + SCRIPT_VERSION + " - MongoDB user permissions audit" + C.reset,
      C.gray + "Lists users, SCRAM mechanisms, direct/inherited roles and the databases they grant." + C.reset,
      "",
      C.bold + "USAGE:" + C.reset,
      "  mongo_exec.sh -c <config> -f mongo_list_users.js [-a <option>]...",
      "  MONGO_SCRIPT_ARGS=\"<options>\" mongosh <uri> --file mongo_list_users.js",
      "",
      C.bold + "OPTIONS:" + C.reset,
      "  " + C.green + "--help, -h" + C.reset + "            Show this help and exit.",
      "  " + C.green + "--json" + C.reset + "                JSON output (array of users) on stdout.",
      "  " + C.green + "--user=<name>" + C.reset + "         Audit a single user (usersInfo with showPrivileges).",
      "  " + C.green + "--auth-db=<db>" + C.reset + "        Authentication database of --user (default: admin).",
      "  " + C.green + "--no-resolve" + C.reset + "          Cluster-wide mode: skip rolesInfo resolution and report",
      "                        direct roles only (needs viewUser only, no viewRole).",
      "  " + C.green + "--compact" + C.reset + "             One line per user: user, auth db, SCRAM, access.",
      "  " + C.green + "--table" + C.reset + "               Full report as a bordered table (roles/access one per line).",
      "  " + C.green + "--no-legend" + C.reset + "           Do not print the legend after the report.",
      "  " + C.green + "--no-color" + C.reset + "            Disable ANSI colors.",
      "",
      C.bold + "REQUIRED PRIVILEGES:" + C.reset,
      "  Cluster-wide: " + C.yellow + "userAdminAnyDatabase" + C.reset + " or " + C.yellow + "root" + C.reset +
        " (viewUser + viewRole on every database).",
      "  Single user:  viewUser on the user's auth database (" + C.yellow + "userAdmin" + C.reset + " on that db).",
      "",
      C.bold + "NOTES:" + C.reset,
      "  - Sharded clusters: connect through mongos. A direct connection to a shard member",
      "    only shows that shard's local users.",
      "  - Access is derived from the actions of the effective privileges. Scopes already",
      "    covered by a broader one are omitted (app:RO is not shown next to *:RW).",
      "",
      legendLines(null).join("\n"),
      "",
      C.bold + "EXAMPLES:" + C.reset,
      "  " + C.gray + "# Cluster-wide audit:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_list_users.js",
      "",
      "  " + C.gray + "# Compact, one line per user:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_list_users.js -a --compact",
      "",
      "  " + C.gray + "# Full report as a table:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_list_users.js -a --table",
      "",
      "  " + C.gray + "# One user, JSON for jq:" + C.reset,
      "  mongo_exec.sh -q -c ~/.mongo/prod.conf -f js/mongo_list_users.js -a --json -a --user=rmateos | jq .",
      "",
      "  " + C.gray + "# Plain mongosh without the wrapper:" + C.reset,
      "  MONGO_SCRIPT_ARGS=\"--user=rmateos --auth-db=admin\" \\",
      "    mongosh \"mongodb://rmateos@127.0.0.1:27017/admin\" --quiet --file js/mongo_list_users.js",
      ""
    ];
    out(lines.join("\n"));
  }

  // --- Arguments ------------------------------------------------------------------
  function rawArgs() {
    if (CTX && CTX.args && CTX.args.length !== undefined) { return CTX.args; }
    if (HAS_PROCESS && process.env.MONGO_SCRIPT_ARGS) {
      return String(process.env.MONGO_SCRIPT_ARGS).split(/\s+/).filter(function (s) { return s.length > 0; });
    }
    return [];
  }

  function parseArgs(args) {
    var o = { help: false, json: false, user: null, authDb: "admin", resolve: true, color: null, compact: false, table: false, legend: true, errors: [] };
    var i = 0;

    function valueOf(arg, name) {
      if (arg.indexOf(name + "=") === 0) { return arg.substring(name.length + 1); }
      if (i + 1 < args.length) { i += 1; return args[i]; }
      o.errors.push("Option " + name + " requires a value.");
      return null;
    }

    for (i = 0; i < args.length; i += 1) {
      var a = String(args[i]);
      if (a === "--help" || a === "-h") { o.help = true; }
      else if (a === "--json") { o.json = true; }
      else if (a === "--no-resolve") { o.resolve = false; }
      else if (a === "--no-color") { o.color = false; }
      else if (a === "--compact") { o.compact = true; }
      else if (a === "--table") { o.table = true; }
      else if (a === "--no-legend") { o.legend = false; }
      else if (a === "--user" || a.indexOf("--user=") === 0) { o.user = valueOf(a, "--user"); }
      else if (a === "--auth-db" || a.indexOf("--auth-db=") === 0) { o.authDb = valueOf(a, "--auth-db"); }
      else { o.errors.push("Unknown option: " + a); }
    }
    if (o.compact && o.table) { o.errors.push("--compact and --table are mutually exclusive."); }
    if (o.user === "") { o.errors.push("--user requires a non-empty value."); }
    if (!o.authDb) { o.errors.push("--auth-db requires a non-empty value."); }
    return o;
  }

  // --- Server helpers ---------------------------------------------------------------
  // mongosh throws on { ok: 0 }, the legacy shell returns it: normalise both.
  function runCmd(database, cmd) {
    var res;
    try {
      res = database.runCommand(cmd);
    } catch (e) {
      return { ok: 0, errmsg: (e && e.message) ? e.message : String(e), code: e ? e.code : undefined };
    }
    if (!res) { return { ok: 0, errmsg: "empty command response" }; }
    return res;
  }

  function describeTopology(adminDb) {
    var info = { version: "unknown", topology: "unknown", shardMember: false };
    try { info.version = adminDb.version(); } catch (e) { /* not fatal */ }

    var hello = runCmd(adminDb, { isMaster: 1 });  // 'hello' only exists from 4.4.2/5.0
    if (hello.ok) {
      if (hello.msg === "isdbgrid") { info.topology = "mongos (sharded cluster)"; }
      else if (hello.setName) { info.topology = "replica set '" + hello.setName + "'"; }
      else { info.topology = "standalone"; }
    }

    if (info.topology.indexOf("mongos") !== 0) {
      var opts = runCmd(adminDb, { getCmdLineOpts: 1 });  // needs clusterMonitor; ignored if denied
      if (opts.ok && opts.parsed && opts.parsed.sharding && opts.parsed.sharding.clusterRole === "shardsvr") {
        info.shardMember = true;
      }
    }
    return info;
  }

  // --- Role / privilege classification ------------------------------------------------
  var ALL_DB_ROLES = {
    readAnyDatabase: 1, readWriteAnyDatabase: 1, userAdminAnyDatabase: 1,
    dbAdminAnyDatabase: 1, root: 1, __system: 1, backup: 1, restore: 1
  };
  var CLUSTER_ROLES = {
    clusterAdmin: 1, clusterManager: 1, clusterMonitor: 1, hostManager: 1,
    __queryableBackup: 1, enableSharding: 1, directShardOperations: 1
  };
  var ALL_DBS = "* (all databases)";
  var ANY_RESOURCE = "* (anyResource)";
  var CLUSTER = "cluster";

  function roleKey(r) { return r.role + "@" + r.db; }

  function dbsFromRoles(roles) {
    var set = {};
    for (var i = 0; i < roles.length; i += 1) {
      var r = roles[i];
      if (r.db === "admin" && ALL_DB_ROLES[r.role]) { set[ALL_DBS] = 1; }
      else if (r.db === "admin" && CLUSTER_ROLES[r.role]) { set[CLUSTER] = 1; }
      else if (r.db) { set[r.db] = 1; }
    }
    return set;
  }

  function dbsFromPrivileges(privs) {
    var set = {};
    for (var i = 0; i < privs.length; i += 1) {
      var res = privs[i] && privs[i].resource;
      if (!res) { continue; }
      if (res.anyResource) { set[ANY_RESOURCE] = 1; }
      else if (res.cluster) { set[CLUSTER] = 1; }
      else if (res.db !== undefined) {
        var coll = (res.collection !== undefined) ? res.collection
          : (res.system_buckets !== undefined ? "system.buckets." + (res.system_buckets || "*") : "");
        if (res.db === "") { set[coll === "" ? ALL_DBS : "*." + coll] = 1; }
        else { set[res.db] = 1; }
      }
    }
    // '*.<collection>' entries are noise once every database is already granted.
    if (set[ALL_DBS] || set[ANY_RESOURCE]) {
      for (var k in set) {
        if (set.hasOwnProperty(k) && k.indexOf("*.") === 0) { delete set[k]; }
      }
    }
    return set;
  }

  function sortedKeys(set) {
    var keys = [];
    for (var k in set) { if (set.hasOwnProperty(k)) { keys.push(k); } }
    keys.sort(function (a, b) {
      var sa = a.charAt(0) === "*" ? 0 : (a === CLUSTER ? 1 : 2);
      var sb = b.charAt(0) === "*" ? 0 : (b === CLUSTER ? 1 : 2);
      if (sa !== sb) { return sa - sb; }
      return a < b ? -1 : (a > b ? 1 : 0);
    });
    return keys;
  }

  function uniqueRoles(list) {
    var seen = {}, res = [];
    for (var i = 0; i < list.length; i += 1) {
      var k = roleKey(list[i]);
      if (!seen[k]) { seen[k] = 1; res.push({ role: list[i].role, db: list[i].db }); }
    }
    res.sort(function (a, b) { var x = roleKey(a), y = roleKey(b); return x < y ? -1 : (x > y ? 1 : 0); });
    return res;
  }

  // --- Abbreviated access model -----------------------------------------------------------
  // Data level per scope (database, '*' = every database, or db.collection):
  //   RO  read-only (find)          RW  read/write (insert/update/remove)
  //   ALL write + db admin + user admin on the scope (dbOwner level) or anyAction
  //   +ADM_DB db administration (collMod/compact/dropDatabase/profiler/...)
  //   +ADM_USR user/role administration (createUser/grantRole/...)
  //   INFO metadata only (dbStats/listCollections/...)   ?  unresolved role
  // (User-facing descriptions: LEVEL_LEGEND / TAG_LEGEND below.)
  // Built-in system/monitoring roles (admin db) are shown as a short tag instead, and
  // their privileges are subtracted so they do not leak into the per-database list.
  var TAG_ORDER = ["SYSTEM", "ROOT", "ANY", "CLU-ADMIN", "CLU-MGR", "MON", "HOST", "BACKUP",
    "RESTORE", "QBACKUP", "SHARDING", "SHARD-DIRECT", "SEARCH", "CLU-OPS", "CLU-RO"];
  // Legend texts: shared by --help and the legend printed after the report.
  var LEVEL_LEGEND = [
    ["RO", "read-only: find on documents"],
    ["RW", "read/write: RO + insert/update/remove (readWrite)"],
    ["ALL", "full control of the scope: RW + ADM_DB + ADM_USR (dbOwner) or anyAction"],
    ["+ADM_DB", "database administration: indexes, collMod, compact, validate, profiler, dropDatabase (dbAdmin)"],
    ["+ADM_USR", "user/role administration: create/drop users, grant/revoke roles, change passwords (userAdmin)"],
    ["INFO", "metadata/stats only, no document access (dbStats, collStats, listCollections)"],
    ["?", "privileges not readable: custom/dropped role, --no-resolve or missing viewRole"]
  ];
  var SCOPE_LEGEND = "<scope>:<level>[+ADM_DB][+ADM_USR]  scope = db | db.coll | db(N colls) | * (all databases)";
  var TAG_LEGEND = {
    "SYSTEM": "__system: internal cluster-member role, unrestricted",
    "ROOT": "root: unrestricted (all data, users and cluster)",
    "ANY": "custom grant on anyResource (unrestricted)",
    "CLU-ADMIN": "clusterAdmin: full cluster management (includes CLU-MGR, MON, HOST)",
    "CLU-MGR": "clusterManager: replica set / sharding configuration and management",
    "MON": "clusterMonitor: read-only monitoring (serverStatus, replSetGetStatus, currentOp)",
    "HOST": "hostManager: server ops (shutdown, logRotate, killOp, fsync, setParameter)",
    "BACKUP": "backup: read every database for backups (mongodump / PBM)",
    "RESTORE": "restore: write every database for restores (mongorestore / PBM)",
    "QBACKUP": "__queryableBackup: internal queryable-backup role",
    "SHARDING": "enableSharding: enable sharding on databases/collections",
    "SHARD-DIRECT": "directShardOperations: direct operations on shard members (8.0+)",
    "SEARCH": "searchCoordinator: search (mongot) coordination",
    "CLU-OPS": "custom role with cluster-level operational actions",
    "CLU-RO": "custom role with cluster-level monitoring actions only"
  };
  var KNOWN_ROLES = {          // only when defined in the admin database
    root: { tag: "ROOT", all: true },
    __system: { tag: "SYSTEM", all: true },
    clusterAdmin: { tag: "CLU-ADMIN" },
    clusterManager: { tag: "CLU-MGR" },
    clusterMonitor: { tag: "MON" },
    hostManager: { tag: "HOST" },
    backup: { tag: "BACKUP" },
    restore: { tag: "RESTORE" },
    __queryableBackup: { tag: "QBACKUP" },
    enableSharding: { tag: "SHARDING" },
    directShardOperations: { tag: "SHARD-DIRECT" },
    searchCoordinator: { tag: "SEARCH" },
    readAnyDatabase: { scope: { r: 1 } },
    readWriteAnyDatabase: { scope: { r: 1, w: 1 } },
    dbAdminAnyDatabase: { scope: { adm: 1 } },
    userAdminAnyDatabase: { scope: { usr: 1 } }
  };
  var TAG_IMPLIES = { "CLU-ADMIN": ["CLU-MGR", "MON", "HOST"] };
  var DB_BUILTINS = {          // fallback when privileges are not available
    read: { r: 1 }, readWrite: { r: 1, w: 1 }, dbAdmin: { adm: 1 }, userAdmin: { usr: 1 },
    dbOwner: { r: 1, w: 1, adm: 1, usr: 1 }
  };
  var ACT_WRITE = { insert: 1, update: 1, remove: 1 };
  var ACT_ADM = { collMod: 1, compact: 1, dropDatabase: 1, enableProfiler: 1, reIndex: 1, validate: 1 };
  var ACT_USR = {
    createUser: 1, dropUser: 1, grantRole: 1, revokeRole: 1, createRole: 1, dropRole: 1,
    changePassword: 1, changeCustomData: 1, setAuthenticationRestriction: 1
  };
  var ACT_CLUSTER_RO = {
    serverStatus: 1, replSetGetStatus: 1, replSetGetConfig: 1, top: 1, inprog: 1, getCmdLineOpts: 1,
    getLog: 1, hostInfo: 1, connPoolStats: 1, netstat: 1, getParameter: 1, listShards: 1,
    getShardMap: 1, listSessions: 1, useUUID: 1, changeStream: 1, getDefaultRWConcern: 1,
    checkFreeMonitoringStatus: 1, getClusterParameter: 1, listDatabases: 1
  };
  var LEVEL_RANK = { "": 0, INFO: 0, RO: 1, RW: 2, ALL: 3 };

  function knownRole(r) { return (r.db === "admin" && KNOWN_ROLES.hasOwnProperty(r.role)) ? KNOWN_ROLES[r.role] : null; }

  function resourceKey(res) {
    if (res.anyResource) { return "ANY"; }
    if (res.cluster) { return "CLUSTER"; }
    var sub = (res.collection !== undefined) ? "c:" + res.collection
      : (res.system_buckets !== undefined ? "b:" + res.system_buckets : "");
    return res.db + "/" + sub;
  }

  // (resource, action) pairs granted by a list of privileges.
  function privilegePairs(privs) {
    var pairs = {};
    for (var i = 0; i < privs.length; i += 1) {
      var p = privs[i];
      if (!p || !p.resource) { continue; }
      var rk = resourceKey(p.resource);
      var acts = p.actions || [];
      for (var j = 0; j < acts.length; j += 1) { pairs[rk + "|" + acts[j]] = 1; }
    }
    return pairs;
  }

  function newScope(key, dbName, coll) {
    return { key: key, db: dbName, coll: coll, r: 0, w: 0, adm: 0, usr: 0, any: 0, meta: 0, unknown: 0 };
  }

  function mergeScope(s, bits) {
    for (var b in bits) { if (bits.hasOwnProperty(b) && bits[b]) { s[b] = 1; } }
  }

  function scopeLevel(s) {
    if (s.any || (s.w && s.adm && s.usr)) { return "ALL"; }
    if (s.w) { return "RW"; }
    if (s.r) { return "RO"; }
    return "";
  }

  function scopeLabel(s) {
    var lvl = scopeLevel(s);
    if (lvl === "ALL") { return lvl; }
    var parts = [];
    if (lvl) { parts.push(lvl); }
    if (s.adm) { parts.push("ADM_DB"); }
    if (s.usr) { parts.push("ADM_USR"); }
    if (parts.length === 0) { return s.unknown ? "?" : "INFO"; }
    return parts.join("+") + (s.unknown ? "?" : "");
  }

  // true when scope b grants at least everything scope a grants.
  function dominates(b, a) {
    if (!b || a.unknown) { return false; }
    var lb = scopeLevel(b), la = scopeLevel(a);
    if (LEVEL_RANK[lb] < LEVEL_RANK[la]) { return false; }
    if (lb === "ALL") { return true; }
    return (!a.adm || b.adm) && (!a.usr || b.usr);
  }

  /**
   * Builds the abbreviated access summary.
   *   effective  all roles of the user (direct + inherited)
   *   privileges merged inherited privileges, or null when unavailable
   *   knownPairs roleKey -> privilege pairs of built-in system roles (may be partial)
   *   fallback   roles whose privileges are unknown (unresolved or --no-resolve)
   */
  function computeAccess(effective, privileges, knownPairs, fallback) {
    var tags = {}, scopes = {}, order = [], i, j, k;

    function scope(key, dbName, coll) {
      if (!scopes[key]) { scopes[key] = newScope(key, dbName, coll); order.push(key); }
      return scopes[key];
    }

    // 1. Built-in system roles -> tags / '*' scope; collect their pairs for subtraction.
    var subtract = {}, missingKnown = false, hasKnown = false;
    for (i = 0; i < effective.length; i += 1) {
      var kr = knownRole(effective[i]);
      if (!kr) { continue; }
      hasKnown = true;
      if (kr.all) { return { tags: [kr.tag], scopes: [], summary: kr.tag }; }
      if (kr.tag) { tags[kr.tag] = 1; } else { mergeScope(scope("*", "*", null), kr.scope); }
      var pairs = knownPairs[roleKey(effective[i])];
      if (pairs) { for (k in pairs) { if (pairs.hasOwnProperty(k)) { subtract[k] = 1; } } }
      else { missingKnown = true; }
    }

    // 2. Remaining privileges -> per-scope bits.
    var clusterActs = {};
    if (privileges !== null) {
      for (i = 0; i < privileges.length; i += 1) {
        var res = privileges[i] && privileges[i].resource;
        if (!res) { continue; }
        var rk = resourceKey(res);
        var acts = privileges[i].actions || [];
        // Without the built-in roles' exact privileges, drop the resources they typically
        // touch (cluster, every-database '*', config/local, system.*) to keep it readable.
        var heuristicDrop = hasKnown && missingKnown && (res.cluster || res.db === "" ||
          res.db === "config" || res.db === "local" ||
          (res.collection !== undefined && String(res.collection).indexOf("system.") === 0));
        for (j = 0; j < acts.length; j += 1) {
          var a = acts[j];
          if (subtract[rk + "|" + a] || heuristicDrop) { continue; }
          if (res.anyResource) { tags.ANY = 1; continue; }
          if (res.cluster) { clusterActs[a] = 1; continue; }
          if (res.db === undefined || res.system_buckets !== undefined) { continue; }
          var coll = res.collection;
          if (coll && coll.indexOf("system.") === 0) { continue; }   // internal collections
          var dbName = res.db === "" ? "*" : res.db;
          var s = coll ? scope(dbName + "." + coll, dbName, coll) : scope(dbName, dbName, null);
          if (a === "anyAction") { s.any = 1; }
          else if (a === "find") { s.r = 1; }
          else if (ACT_WRITE[a]) { s.w = 1; }
          else if (ACT_ADM[a]) { s.adm = 1; }
          else if (ACT_USR[a]) { s.usr = 1; }
          else { s.meta = 1; }
        }
      }
    }

    // 3. Roles without privilege data: map built-in db roles by name; custom or dropped
    //    roles are listed by name as 'role@db:?' (a custom role may grant on any db).
    var unknownRoles = [];
    for (i = 0; i < fallback.length; i += 1) {
      var fr = fallback[i];
      if (knownRole(fr)) { continue; }
      if (DB_BUILTINS.hasOwnProperty(fr.role)) { mergeScope(scope(fr.db, fr.db, null), DB_BUILTINS[fr.role]); }
      else { unknownRoles.push(roleKey(fr)); }
    }

    // 4. Custom cluster-level grants (listDatabases alone is too common to be worth a tag).
    delete clusterActs.listDatabases;
    var clusterRO = true, anyCluster = false;
    for (k in clusterActs) {
      if (clusterActs.hasOwnProperty(k)) { anyCluster = true; if (!ACT_CLUSTER_RO[k]) { clusterRO = false; } }
    }
    if (anyCluster) { tags[clusterRO ? "CLU-RO" : "CLU-OPS"] = 1; }
    for (k in TAG_IMPLIES) {
      if (TAG_IMPLIES.hasOwnProperty(k) && tags[k]) {
        for (j = 0; j < TAG_IMPLIES[k].length; j += 1) { delete tags[TAG_IMPLIES[k][j]]; }
      }
    }

    // 5. Drop scopes already covered by a broader one, collapse collection grants.
    var star = scopes["*"];
    var kept = [], collsByDb = {};
    for (i = 0; i < order.length; i += 1) {
      var sc = scopes[order[i]];
      if (!sc.r && !sc.w && !sc.adm && !sc.usr && !sc.any && !sc.unknown && !sc.meta) { continue; }
      if (sc.key !== "*" && dominates(star, sc)) { continue; }
      if (sc.coll) {
        if (dominates(scopes[sc.db], sc) || dominates(scopes["*." + sc.coll], sc)) { continue; }
        if (!collsByDb[sc.db]) { collsByDb[sc.db] = []; }
        collsByDb[sc.db].push(sc);
        continue;
      }
      kept.push({ name: sc.key, label: scopeLabel(sc) });
    }
    for (var d in collsByDb) {
      if (!collsByDb.hasOwnProperty(d)) { continue; }
      var list = collsByDb[d], byLabel = {};
      for (i = 0; i < list.length; i += 1) {
        var lb = scopeLabel(list[i]);
        if (!byLabel[lb]) { byLabel[lb] = []; }
        byLabel[lb].push(list[i].coll);
      }
      for (var l in byLabel) {
        if (!byLabel.hasOwnProperty(l)) { continue; }
        if (byLabel[l].length <= 2) {
          for (i = 0; i < byLabel[l].length; i += 1) { kept.push({ name: d + "." + byLabel[l][i], label: l }); }
        } else {
          kept.push({ name: d + "(" + byLabel[l].length + " colls)", label: l });
        }
      }
    }
    kept.sort(function (x, y) {
      var sx = x.name.charAt(0) === "*" ? 0 : 1, sy = y.name.charAt(0) === "*" ? 0 : 1;
      if (sx !== sy) { return sx - sy; }
      return x.name < y.name ? -1 : (x.name > y.name ? 1 : 0);
    });

    for (i = 0; i < unknownRoles.length; i += 1) { kept.push({ name: unknownRoles[i], label: "?" }); }

    var tagList = [];
    for (i = 0; i < TAG_ORDER.length; i += 1) { if (tags[TAG_ORDER[i]]) { tagList.push(TAG_ORDER[i]); } }
    var parts = tagList.slice(0);
    for (i = 0; i < kept.length; i += 1) { parts.push(kept[i].name + ":" + kept[i].label); }
    return { tags: tagList, scopes: kept, summary: parts.length ? parts.join(", ") : "NONE" };
  }

  // Privilege pairs of the built-in system roles present in any user's effective roles.
  function fetchKnownPairs(effectiveLists, cache) {
    var pairs = {}, wanted = [], seen = {}, i, j;
    for (i = 0; i < effectiveLists.length; i += 1) {
      for (j = 0; j < effectiveLists[i].length; j += 1) {
        var r = effectiveLists[i][j], kr = knownRole(r), key = roleKey(r);
        if (!kr || kr.all || seen[key]) { continue; }
        seen[key] = 1;
        if (cache[key] && cache[key].inheritedPrivileges) { pairs[key] = privilegePairs(cache[key].inheritedPrivileges); }
        else { wanted.push({ role: r.role, db: "admin" }); }
      }
    }
    if (wanted.length > 0) {
      var res = runCmd(db.getSiblingDB("admin"), { rolesInfo: wanted, showPrivileges: true });
      if (res.ok) {
        var docs = res.roles || [];
        for (i = 0; i < docs.length; i += 1) { pairs[roleKey(docs[i])] = privilegePairs(docs[i].inheritedPrivileges || []); }
      }
    }
    return pairs;
  }

  // --- Cluster-wide role resolution (rolesInfo, grouped per database) ------------------
  function resolveRoles(users) {
    var byDb = {}, cache = {}, denied = [];
    var i, j;
    for (i = 0; i < users.length; i += 1) {
      var roles = users[i].roles || [];
      for (j = 0; j < roles.length; j += 1) {
        if (!byDb[roles[j].db]) { byDb[roles[j].db] = {}; }
        byDb[roles[j].db][roles[j].role] = 1;
      }
    }
    for (var dbName in byDb) {
      if (!byDb.hasOwnProperty(dbName)) { continue; }
      var wanted = [];
      for (var rn in byDb[dbName]) {
        if (byDb[dbName].hasOwnProperty(rn)) { wanted.push({ role: rn, db: dbName }); }
      }
      var res = runCmd(db.getSiblingDB(dbName), { rolesInfo: wanted, showPrivileges: true });
      if (!res.ok) { denied.push(dbName + " (" + res.errmsg + ")"); continue; }
      var docs = res.roles || [];
      for (j = 0; j < docs.length; j += 1) { cache[roleKey(docs[j])] = docs[j]; }
    }
    return { cache: cache, denied: denied };
  }

  // --- Per-user model ----------------------------------------------------------------
  function buildUser(u, mode, cache) {
    var direct = uniqueRoles(u.roles || []);
    var effective = direct.slice(0);
    var privileges = null;
    var unresolved = [];
    var i, j;

    if (mode === "single") {
      effective = uniqueRoles((u.inheritedRoles || []).concat(direct));
      privileges = u.inheritedPrivileges || [];
    } else if (mode === "resolved") {
      privileges = [];
      var acc = direct.slice(0);
      for (i = 0; i < direct.length; i += 1) {
        var doc = cache[roleKey(direct[i])];
        if (!doc) { unresolved.push(roleKey(direct[i])); continue; }
        acc = acc.concat(doc.inheritedRoles || []);
        var ip = doc.inheritedPrivileges || doc.privileges || [];
        for (j = 0; j < ip.length; j += 1) { privileges.push(ip[j]); }
      }
      effective = uniqueRoles(acc);
    }

    // Fall back to role-based scoping for roles we could not resolve.
    var dbSet = (privileges !== null && unresolved.length < direct.length)
      ? dbsFromPrivileges(privileges) : dbsFromRoles(direct);
    if (unresolved.length > 0 && privileges !== null) {
      var extra = dbsFromRoles(direct.filter(function (r) { return unresolved.indexOf(roleKey(r)) !== -1; }));
      for (var k in extra) { if (extra.hasOwnProperty(k)) { dbSet[k] = 1; } }
    }

    var directKeys = {};
    for (i = 0; i < direct.length; i += 1) { directKeys[roleKey(direct[i])] = 1; }
    var inheritedOnly = [];
    for (i = 0; i < effective.length; i += 1) {
      if (!directKeys[roleKey(effective[i])]) { inheritedOnly.push(roleKey(effective[i])); }
    }

    var model = {
      user: u.user,
      authenticationDatabase: u.db,
      mechanisms: u.mechanisms || [],
      directRoles: direct.map(roleKey),
      inheritedRoles: inheritedOnly,
      authorizedDatabases: sortedKeys(dbSet),
      resolution: privileges !== null ? "privileges" : "roles"
    };
    if (unresolved.length > 0) { model.unresolvedRoles = unresolved; }
    // Inputs for computeAccess(); removed before output.
    model._effective = effective;
    model._privileges = privileges;
    model._fallback = (privileges === null) ? direct
      : direct.filter(function (r) { return unresolved.indexOf(roleKey(r)) !== -1; });
    if (u.authenticationRestrictions && u.authenticationRestrictions.length) {
      model.authenticationRestrictions = u.authenticationRestrictions;
    }
    return model;
  }

  // --- Rendering -----------------------------------------------------------------------
  function colorLabel(label) {
    var lvl = String(label).replace(/^\+/, "").split("+")[0].replace("?", "").replace(/ +$/, "");
    var col = lvl === "ALL" ? C.red : (lvl === "RW" ? C.yellow : (lvl === "RO" ? C.green : C.gray));
    return col + label + C.reset;
  }

  // Access entries as { t: plain text (for width), s: styled text }.
  function accessItems(u) {
    var items = [], i;
    for (i = 0; i < u.accessTags.length; i += 1) {
      var t = u.accessTags[i];
      items.push({ t: t, s: (t === "ROOT" || t === "SYSTEM" || t === "ANY" ? C.red : C.magenta) + C.bold + t + C.reset });
    }
    for (var name in u.accessScopes) {
      if (u.accessScopes.hasOwnProperty(name)) {
        items.push({ t: name + ":" + u.accessScopes[name], s: name + ":" + colorLabel(u.accessScopes[name]) });
      }
    }
    if (items.length === 0) { items.push({ t: "NONE", s: C.gray + "NONE" + C.reset }); }
    return items;
  }

  function colorAccess(u) {
    var items = accessItems(u), parts = [];
    for (var i = 0; i < items.length; i += 1) { parts.push(items[i].s); }
    return parts.join(", ");
  }

  // SCRAM mechanisms, abbreviated; SCRAM-SHA-1 only is highlighted.
  function mechShort(u) {
    var m = u.mechanisms;
    if (m.length === 1 && m[0] === "SCRAM-SHA-1") { return { t: "SHA1", s: C.yellow + "SHA1" + C.reset }; }
    if (m.length === 1 && m[0] === "SCRAM-SHA-256") { return { t: "SHA256", s: "SHA256" }; }
    if (m.length === 2 && m.indexOf("SCRAM-SHA-1") !== -1 && m.indexOf("SCRAM-SHA-256") !== -1) {
      return { t: "BOTH", s: "BOTH" };
    }
    var txt = m.length ? m.join("/") : "n/a";
    return { t: txt, s: txt };
  }

  function plainCell(list, style, emptyText) {
    var cell = [], i;
    for (i = 0; i < list.length; i += 1) {
      cell.push({ t: String(list[i]), s: (style || "") + list[i] + (style ? C.reset : "") });
    }
    if (cell.length === 0) { cell.push({ t: emptyText, s: C.gray + emptyText + C.reset }); }
    return cell;
  }

  // Generic grid: cols = [header], rows = [[cell]], cell = [{t, s}] (one entry per line).
  function renderGrid(cols, rows) {
    var widths = [], i, c, k;
    for (c = 0; c < cols.length; c += 1) { widths.push(cols[c].length); }
    for (i = 0; i < rows.length; i += 1) {
      for (c = 0; c < cols.length; c += 1) {
        for (k = 0; k < rows[i][c].length; k += 1) { widths[c] = Math.max(widths[c], rows[i][c][k].t.length); }
      }
    }
    var sepParts = [];
    for (c = 0; c < cols.length; c += 1) { sepParts.push(repeatStr("-", widths[c] + 2)); }
    var sep = C.gray + "+" + sepParts.join("+") + "+" + C.reset;
    var bar = C.gray + "|" + C.reset;

    var head = [];
    for (c = 0; c < cols.length; c += 1) { head.push(" " + C.bold + pad(cols[c], widths[c]) + C.reset + " "); }
    out(sep);
    out(bar + head.join(bar) + bar);
    out(sep);
    for (i = 0; i < rows.length; i += 1) {
      var height = 1;
      for (c = 0; c < cols.length; c += 1) { height = Math.max(height, rows[i][c].length); }
      for (k = 0; k < height; k += 1) {
        var line = [];
        for (c = 0; c < cols.length; c += 1) {
          var e = rows[i][c][k];
          line.push(" " + (e ? e.s + repeatStr(" ", widths[c] - e.t.length) : repeatStr(" ", widths[c])) + " ");
        }
        out(bar + line.join(bar) + bar);
      }
      out(sep);
    }
  }

  function repeatStr(ch, n) {
    var r = "";
    while (r.length < n) { r += ch; }
    return r;
  }

  function pad(str, len) {
    var s = String(str);
    while (s.length < len) { s += " "; }
    return s;
  }

  function renderHeader(info, users, mode) {
    var modeLabel = mode === "single" ? "single user, showPrivileges"
      : (mode === "resolved" ? "cluster-wide, roles resolved via rolesInfo" : "cluster-wide, direct roles only");
    out("");
    out(C.bold + C.cyan + "=== MONGODB USER PRIVILEGES AUDIT ===" + C.reset);
    out(C.gray + "Server: " + info.version + " | Topology: " + info.topology + " | Mode: " + modeLabel + C.reset);
    out(C.gray + "Users: " + users.length + C.reset);
    out("");
  }

  // One line per user: user@authdb, mechanisms, access summary.
  function renderCompact(info, users, mode) {
    renderHeader(info, users, mode);
    var wu = 4, wd = 7, wm = 5, i;
    for (i = 0; i < users.length; i += 1) {
      wu = Math.max(wu, users[i].user.length);
      wd = Math.max(wd, users[i].authenticationDatabase.length);
      wm = Math.max(wm, mechShort(users[i]).t.length);
    }
    out(C.bold + pad("USER", wu) + "  " + pad("AUTH_DB", wd) + "  " + pad("SCRAM", wm) + "  ACCESS" + C.reset);
    for (i = 0; i < users.length; i += 1) {
      var u = users[i], mech = mechShort(u);
      out(C.green + pad(u.user, wu) + C.reset + "  " + C.yellow + pad(u.authenticationDatabase, wd) + C.reset + "  " +
        mech.s + repeatStr(" ", wm - mech.t.length) + "  " + colorAccess(u));
    }
  }

  // Full report as a grid; list values one per line inside the cell.
  function renderTable(info, users, mode) {
    renderHeader(info, users, mode);
    var showInherited = false, showRestrictions = false, i;
    for (i = 0; i < users.length; i += 1) {
      if (users[i].resolution === "privileges") { showInherited = true; }
      if (users[i].authenticationRestrictions) { showRestrictions = true; }
    }
    var cols = ["#", "USER", "AUTH_DB", "SCRAM", "DIRECT ROLES"];
    if (showInherited) { cols.push("INHERITED ROLES"); }
    cols.push("ACCESS");
    if (showRestrictions) { cols.push("AUTH RESTRICTIONS"); }

    var rows = [];
    for (i = 0; i < users.length; i += 1) {
      var u = users[i];
      var mechs = [], k;
      for (k = 0; k < u.mechanisms.length; k += 1) { mechs.push(u.mechanisms[k].replace(/^SCRAM-/, "")); }
      var mechCell = plainCell(mechs, (mechs.length === 1 && mechs[0] === "SHA-1") ? C.yellow : "", "n/a");
      var row = [
        plainCell([String(i + 1)], "", ""),
        plainCell([u.user], C.green, ""),
        plainCell([u.authenticationDatabase], C.yellow, ""),
        mechCell,
        plainCell(u.directRoles, "", "None")
      ];
      if (showInherited) {
        row.push(u.resolution === "privileges" ? plainCell(u.inheritedRoles, "", "None") : plainCell([], "", "n/a"));
      }
      row.push(accessItems(u));
      if (showRestrictions) {
        var restr = [];
        var ar = u.authenticationRestrictions || [];
        for (k = 0; k < ar.length; k += 1) { restr.push(JSON.stringify(ar[k])); }
        row.push(plainCell(restr, "", "-"));
      }
      rows.push(row);
    }
    renderGrid(cols, rows);
  }

  function legendLines(tagsUsed) {
    var lines = [], i, w = 12;
    lines.push(C.bold + "Legend" + C.reset + C.gray + "  " + SCOPE_LEGEND + C.reset);
    for (i = 0; i < LEVEL_LEGEND.length; i += 1) {
      lines.push("  " + colorLabel(pad(LEVEL_LEGEND[i][0], w)) + " " + C.gray + LEVEL_LEGEND[i][1] + C.reset);
    }
    var tags = [];
    for (i = 0; i < TAG_ORDER.length; i += 1) {
      if (!tagsUsed || tagsUsed[TAG_ORDER[i]]) { tags.push(TAG_ORDER[i]); }
    }
    if (tags.length) {
      lines.push(C.gray + "  Tags (built-in system roles, shown instead of their privileges):" + C.reset);
      for (i = 0; i < tags.length; i += 1) {
        lines.push("  " + C.magenta + C.bold + pad(tags[i], w) + C.reset + " " + C.gray + TAG_LEGEND[tags[i]] + C.reset);
      }
    }
    return lines;
  }

  // Levels are always listed (a level can be implied, e.g. ALL = RW+ADM_DB+ADM_USR); tags only
  // when they appear in the report.
  function renderLegend(users) {
    var used = {}, i, k;
    for (i = 0; i < users.length; i += 1) {
      for (k = 0; k < users[i].accessTags.length; k += 1) { used[users[i].accessTags[k]] = 1; }
    }
    out("");
    out(legendLines(used).join("\n"));
  }

  function renderText(info, users, mode) {
    renderHeader(info, users, mode);

    for (var i = 0; i < users.length; i += 1) {
      var u = users[i];
      var mech = u.mechanisms.length ? u.mechanisms.join(", ") : "n/a";
      if (u.mechanisms.length === 1 && u.mechanisms[0] === "SCRAM-SHA-1") {
        mech = C.yellow + mech + " (no SCRAM-SHA-256)" + C.reset;
      }
      out(C.bold + "[" + (i + 1) + "] User:" + C.reset + " " + C.green + u.user + C.reset +
        " (AuthDB: " + C.yellow + u.authenticationDatabase + C.reset + ")");
      out("    " + C.bold + "Mechanisms:" + C.reset + "      " + mech);
      out("    " + C.bold + "Direct roles:" + C.reset + "    " +
        (u.directRoles.length ? u.directRoles.join(", ") : C.gray + "None" + C.reset));
      if (u.resolution === "privileges") {
        out("    " + C.bold + "Inherited roles:" + C.reset + " " +
          (u.inheritedRoles.length ? u.inheritedRoles.join(", ") : C.gray + "None" + C.reset));
      }
      out("    " + C.bold + "Access:" + C.reset + "          " + colorAccess(u));
      if (u.unresolvedRoles) {
        out("    " + C.bold + C.yellow + "Unresolved:" + C.reset + "      " + u.unresolvedRoles.join(", "));
      }
      if (u.authenticationRestrictions) {
        out("    " + C.bold + "Auth restrictions:" + C.reset + " " + JSON.stringify(u.authenticationRestrictions));
      }
      out(C.gray + "------------------------------------------------------------" + C.reset);
    }
  }

  // --- Main ------------------------------------------------------------------------------
  function main() {
    var opts = parseArgs(rawArgs());
    setColors(opts.color === false ? false : (opts.json ? false : useColor()));

    if (opts.help) { printHelp(); return; }
    if (opts.errors.length) {
      fail(2, opts.errors.join(" ") + " Use --help for usage.");
    }
    if ((CTX && CTX.nodb) || typeof db === "undefined" || !db) {
      fail(2, "This script needs a database connection (running with --nodb).");
    }

    var adminDb = db.getSiblingDB("admin");
    var info = describeTopology(adminDb);
    if (info.shardMember) {
      warn("Connected directly to a shard member: only shard-local users are listed. Connect through mongos for cluster users.");
    }

    var mode, cmd;
    if (opts.user) {
      mode = "single";
      cmd = { usersInfo: { user: opts.user, db: opts.authDb }, showPrivileges: true };
    } else {
      // showPrivileges is rejected together with forAllDBs: resolve roles separately.
      mode = opts.resolve ? "resolved" : "direct";
      cmd = { usersInfo: { forAllDBs: true } };
    }

    var result = runCmd(adminDb, cmd);
    if (!result.ok) { fail(1, "usersInfo failed: " + result.errmsg); }

    var raw = result.users || [];
    raw.sort(function (a, b) {
      var x = a.db + "." + a.user, y = b.db + "." + b.user;
      return x < y ? -1 : (x > y ? 1 : 0);
    });

    var cache = {};
    if (mode === "resolved" && raw.length > 0) {
      var resolved = resolveRoles(raw);
      cache = resolved.cache;
      if (resolved.denied.length > 0) {
        warn("rolesInfo failed on: " + resolved.denied.join("; ") +
          ". Affected users fall back to direct roles (grant viewRole or use --no-resolve).");
      }
    }

    var users = [], i;
    for (i = 0; i < raw.length; i += 1) { users.push(buildUser(raw[i], mode, cache)); }

    var knownPairs = {};
    if (mode !== "direct") {
      var effLists = [];
      for (i = 0; i < users.length; i += 1) { effLists.push(users[i]._effective); }
      knownPairs = fetchKnownPairs(effLists, cache);
    }
    for (i = 0; i < users.length; i += 1) {
      var u = users[i];
      var acc = computeAccess(u._effective, u._privileges, knownPairs, u._fallback);
      u.access = acc.summary;
      u.accessTags = acc.tags;
      u.accessScopes = {};
      for (var j = 0; j < acc.scopes.length; j += 1) { u.accessScopes[acc.scopes[j].name] = acc.scopes[j].label; }
      delete u._effective; delete u._privileges; delete u._fallback;
    }

    if (opts.json) {
      out(JSON.stringify(users, null, 2));
      if (users.length === 0 && mode === "single") { quit(1); }
      return;
    }
    if (users.length === 0) {
      if (mode === "single") { fail(1, "User '" + opts.user + "' not found in database '" + opts.authDb + "'."); }
      warn("No users found.");
      return;
    }
    if (opts.compact) { renderCompact(info, users, mode); }
    else if (opts.table) { renderTable(info, users, mode); }
    else { renderText(info, users, mode); }
    if (opts.legend) { renderLegend(users); }
  }

  main();
})();
