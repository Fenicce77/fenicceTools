/**
 * Script: mongo_list_users.js
 * Description: Audits MongoDB users: authentication database, SCRAM mechanisms, direct
 *              and inherited roles, and the databases/resources those roles grant.
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
  var SCRIPT_VERSION = "2.0.0";

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
      "  - 'Databases' is derived from inherited privileges when roles are resolved; '*' means",
      "    all non-system collections of every database, 'cluster' a cluster-level resource.",
      "",
      C.bold + "EXAMPLES:" + C.reset,
      "  " + C.gray + "# Cluster-wide audit:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_list_users.js",
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
    var o = { help: false, json: false, user: null, authDb: "admin", resolve: true, color: null, errors: [] };
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
      else if (a === "--user" || a.indexOf("--user=") === 0) { o.user = valueOf(a, "--user"); }
      else if (a === "--auth-db" || a.indexOf("--auth-db=") === 0) { o.authDb = valueOf(a, "--auth-db"); }
      else { o.errors.push("Unknown option: " + a); }
    }
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
    if (u.authenticationRestrictions && u.authenticationRestrictions.length) {
      model.authenticationRestrictions = u.authenticationRestrictions;
    }
    return model;
  }

  // --- Rendering -----------------------------------------------------------------------
  function renderText(info, users, mode) {
    var modeLabel = mode === "single" ? "single user, showPrivileges"
      : (mode === "resolved" ? "cluster-wide, roles resolved via rolesInfo" : "cluster-wide, direct roles only");
    out("");
    out(C.bold + C.cyan + "=== MONGODB USER PRIVILEGES AUDIT ===" + C.reset);
    out(C.gray + "Server: " + info.version + " | Topology: " + info.topology + " | Mode: " + modeLabel + C.reset);
    out(C.gray + "Users: " + users.length + C.reset);
    out("");

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
      out("    " + C.bold + "Databases:" + C.reset + "       " + C.magenta +
        (u.authorizedDatabases.length ? u.authorizedDatabases.join(", ") : "None") + C.reset);
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

    var users = [];
    for (var i = 0; i < raw.length; i += 1) { users.push(buildUser(raw[i], mode, cache)); }

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
    renderText(info, users, mode);
  }

  main();
})();
