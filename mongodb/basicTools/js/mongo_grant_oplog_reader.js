/**
 * Script: mongo_grant_oplog_reader.js
 * Description: Idempotently creates/reconciles a custom role (default 'oplogReader', in the
 *              admin database) granting 'find' on local.oplog.rs, and grants it to a user.
 * Compatibility: mongosh 1.x/2.x and the legacy mongo shell 4.x, against MongoDB 4.0 - 8.x
 *              replica sets. ES5 syntax on purpose (legacy shell); shell API calls are kept
 *              out of array callbacks (mongosh async-rewriter limitation).
 *
 * Arguments (first match wins):
 *   1. MONGO_EXEC_CTX.args  - set by sh/mongo_exec.sh (-a <arg>).
 *   2. MONGO_SCRIPT_ARGS     - environment variable, mongosh only.
 *
 * Exit codes: 0 ok (or nothing to do), 1 server/command error or user not found,
 *             2 usage error.
 */
(function () {
  var SCRIPT_VERSION = "1.0.0";

  var DEFAULT_ROLE = "oplogReader";
  var ROLE_DB = "admin";
  var ROLE_PRIVILEGES = [
    { resource: { db: "local", collection: "oplog.rs" }, actions: ["find"] }
  ];

  // --- Runtime detection ----------------------------------------------------------
  var CTX = (typeof MONGO_EXEC_CTX !== "undefined" && MONGO_EXEC_CTX) ? MONGO_EXEC_CTX : null;
  var HAS_PROCESS = (typeof process !== "undefined" && process && process.env);
  // mongosh runs on Node (process is defined); the legacy shell has no stderr writer.
  var HAS_CONSOLE = !!(HAS_PROCESS && process.versions && typeof console !== "undefined" &&
    typeof console.error === "function");

  var C = { reset: "", bold: "", cyan: "", green: "", yellow: "", red: "", gray: "" };

  function setColors(enabled) {
    var on = { reset: "\x1b[0m", bold: "\x1b[1m", cyan: "\x1b[36m", green: "\x1b[32m",
      yellow: "\x1b[33m", red: "\x1b[31m", gray: "\x1b[90m" };
    for (var k in on) { if (on.hasOwnProperty(k)) { C[k] = enabled ? on[k] : ""; } }
  }

  function useColor() {
    if (CTX && typeof CTX.color === "boolean") { return CTX.color; }
    if (HAS_PROCESS) { return !!(process.stdout && process.stdout.isTTY) && !process.env.NO_COLOR; }
    return false;
  }

  function out(msg) { print(msg); }
  function err(msg) { if (HAS_CONSOLE) { console.error(msg); } else { print(msg); } }
  function info(msg) { out(C.cyan + "[INFO]" + C.reset + " " + msg); }
  function ok(msg) { out(C.green + "[OK]" + C.reset + " " + msg); }
  function skip(msg) { out(C.gray + "[SKIP]" + C.reset + " " + msg); }
  function plan(msg) { out(C.yellow + "[DRY-RUN]" + C.reset + " " + msg); }
  function warn(msg) { err(C.yellow + "[WARN]" + C.reset + " " + msg); }
  function fail(code, msg) { err(C.red + "[ERROR]" + C.reset + " " + msg); quit(code); }

  // --- Help -------------------------------------------------------------------------
  function printHelp() {
    out([
      "",
      C.bold + C.cyan + "mongo_grant_oplog_reader.js " + SCRIPT_VERSION + " - grant read access to the oplog" + C.reset,
      C.gray + "Creates or reconciles a custom role with 'find' on local.oplog.rs and grants it to a user." + C.reset,
      C.gray + "Idempotent: re-running only changes what differs." + C.reset,
      "",
      C.bold + "USAGE:" + C.reset,
      "  mongo_exec.sh -c <config> -f mongo_grant_oplog_reader.js -a --user=<name> [-a <option>]...",
      "  MONGO_SCRIPT_ARGS=\"--user=<name>\" mongosh <uri> --file mongo_grant_oplog_reader.js",
      "",
      C.bold + "OPTIONS:" + C.reset,
      "  " + C.green + "--user=<name>" + C.reset + "      User to grant the role to (required).",
      "  " + C.green + "--auth-db=<db>" + C.reset + "     Authentication database of the user (default: admin).",
      "  " + C.green + "--role=<name>" + C.reset + "      Role name, created in the admin database (default: " + DEFAULT_ROLE + ").",
      "  " + C.green + "--dry-run" + C.reset + "          Show what would change, without changing anything.",
      "  " + C.green + "--no-color" + C.reset + "         Disable ANSI colors.",
      "  " + C.green + "--help, -h" + C.reset + "         Show this help and exit.",
      "",
      C.bold + "BEHAVIOUR:" + C.reset,
      "  - Role missing           -> createRole.",
      "  - Role with other privs  -> updateRole: privileges are REPLACED by find on local.oplog.rs",
      "                              (any extra privilege on that role is removed; check --dry-run).",
      "  - Role already granted   -> skipped.",
      "  - Must run against the primary (use a replica set URI / mongo_exec.sh config).",
      "",
      C.bold + "REQUIRED PRIVILEGES:" + C.reset,
      "  createRole/updateRole/viewRole on admin and grantRole/viewUser on the user's auth db",
      "  (" + C.yellow + "userAdminAnyDatabase" + C.reset + " or " + C.yellow + "root" + C.reset + ").",
      "",
      C.bold + "EXAMPLES:" + C.reset,
      "  " + C.gray + "# Preview:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_grant_oplog_reader.js -a --user=rmateos -a --dry-run",
      "",
      "  " + C.gray + "# Apply for a user defined in another auth db:" + C.reset,
      "  mongo_exec.sh -c ~/.mongo/prod.conf -f js/mongo_grant_oplog_reader.js -a --user=cdc_app -a --auth-db=app",
      ""
    ].join("\n"));
  }

  // --- Arguments ----------------------------------------------------------------------
  function rawArgs() {
    if (CTX && CTX.args && CTX.args.length !== undefined) { return CTX.args; }
    if (HAS_PROCESS && process.env.MONGO_SCRIPT_ARGS) {
      return String(process.env.MONGO_SCRIPT_ARGS).split(/\s+/).filter(function (s) { return s.length > 0; });
    }
    return [];
  }

  function parseArgs(args) {
    var o = { help: false, user: null, authDb: "admin", role: DEFAULT_ROLE, dryRun: false, color: null, errors: [] };
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
      else if (a === "--dry-run") { o.dryRun = true; }
      else if (a === "--no-color") { o.color = false; }
      else if (a === "--user" || a.indexOf("--user=") === 0) { o.user = valueOf(a, "--user"); }
      else if (a === "--auth-db" || a.indexOf("--auth-db=") === 0) { o.authDb = valueOf(a, "--auth-db"); }
      else if (a === "--role" || a.indexOf("--role=") === 0) { o.role = valueOf(a, "--role"); }
      else { o.errors.push("Unknown option: " + a); }
    }
    if (!o.help && !o.user) { o.errors.push("--user is required."); }
    if (!o.authDb) { o.errors.push("--auth-db requires a non-empty value."); }
    if (!o.role) { o.errors.push("--role requires a non-empty value."); }
    return o;
  }

  // --- Server helpers -------------------------------------------------------------------
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

  // Order-independent signature of a privilege list, for comparison.
  function privilegeSignature(privs) {
    var items = [], i;
    for (i = 0; i < privs.length; i += 1) {
      var r = privs[i].resource || {};
      var acts = (privs[i].actions || []).slice(0).sort();
      items.push(JSON.stringify([r.db, r.collection, !!r.cluster, !!r.anyResource, acts]));
    }
    items.sort();
    return items.join("|");
  }

  function describePrivileges(privs) {
    var parts = [], i;
    for (i = 0; i < privs.length; i += 1) {
      var r = privs[i].resource || {};
      var res = r.cluster ? "cluster" : (r.anyResource ? "anyResource"
        : (r.db === "" ? "*" : r.db) + "." + (r.collection === "" ? "*" : r.collection));
      parts.push(res + ":[" + (privs[i].actions || []).join(",") + "]");
    }
    return parts.length ? parts.join(" ") : "none";
  }

  // --- Main ------------------------------------------------------------------------------
  function main() {
    var opts = parseArgs(rawArgs());
    setColors(opts.color === false ? false : useColor());

    if (opts.help) { printHelp(); return; }
    if (opts.errors.length) { fail(2, opts.errors.join(" ") + " Use --help for usage."); }
    if ((CTX && CTX.nodb) || typeof db === "undefined" || !db) {
      fail(2, "This script needs a database connection (running with --nodb).");
    }

    var adminDb = db.getSiblingDB(ROLE_DB);
    var userDb = db.getSiblingDB(opts.authDb);

    // User management writes go to the primary.
    var hello = runCmd(adminDb, { isMaster: 1 });  // 'hello' only exists from 4.4.2/5.0
    if (!hello.ok) { fail(1, "isMaster failed: " + hello.errmsg); }
    if (!hello.ismaster && hello.msg !== "isdbgrid") {
      fail(1, "Connected to a non-primary member" + (hello.setName ? " of '" + hello.setName + "'" : "") +
        ". Use a replica set URI so writes reach the primary.");
    }
    if (opts.dryRun) { info("Dry run: no changes will be made."); }

    // 1. Target user.
    var ures = runCmd(userDb, { usersInfo: { user: opts.user, db: opts.authDb } });
    if (!ures.ok) { fail(1, "usersInfo failed: " + ures.errmsg); }
    if (!ures.users || ures.users.length === 0) {
      fail(1, "User '" + opts.user + "' not found in database '" + opts.authDb + "'.");
    }
    var userDoc = ures.users[0];

    // 2. Role: create or reconcile.
    var rres = runCmd(adminDb, { rolesInfo: { role: opts.role, db: ROLE_DB }, showPrivileges: true });
    if (!rres.ok) { fail(1, "rolesInfo failed: " + rres.errmsg); }
    var roleDoc = (rres.roles && rres.roles.length) ? rres.roles[0] : null;
    var roleId = opts.role + "@" + ROLE_DB;
    var res;

    if (roleDoc && roleDoc.isBuiltin) {
      fail(2, "'" + roleId + "' is a built-in role; choose another name with --role.");
    }
    if (!roleDoc) {
      if (opts.dryRun) {
        plan("Would create role " + roleId + " with " + describePrivileges(ROLE_PRIVILEGES) + ".");
      } else {
        res = runCmd(adminDb, { createRole: opts.role, privileges: ROLE_PRIVILEGES, roles: [] });
        if (!res.ok) { fail(1, "createRole failed: " + res.errmsg); }
        ok("Role " + roleId + " created: " + describePrivileges(ROLE_PRIVILEGES) + ".");
      }
    } else {
      var current = roleDoc.privileges || [];
      var inherited = roleDoc.roles || [];
      if (privilegeSignature(current) === privilegeSignature(ROLE_PRIVILEGES) && inherited.length === 0) {
        skip("Role " + roleId + " already up to date.");
      } else {
        var change = "privileges " + describePrivileges(current) + " -> " + describePrivileges(ROLE_PRIVILEGES) +
          (inherited.length ? "; inherited roles removed: " + inherited.length : "");
        if (opts.dryRun) {
          plan("Would update role " + roleId + ": " + change + ".");
        } else {
          res = runCmd(adminDb, { updateRole: opts.role, privileges: ROLE_PRIVILEGES, roles: [] });
          if (!res.ok) { fail(1, "updateRole failed: " + res.errmsg); }
          ok("Role " + roleId + " reconciled: " + change + ".");
        }
      }
    }

    // 3. Grant.
    var granted = false, i;
    var uroles = userDoc.roles || [];
    for (i = 0; i < uroles.length; i += 1) {
      if (uroles[i].role === opts.role && uroles[i].db === ROLE_DB) { granted = true; }
    }
    var userId = opts.user + "@" + opts.authDb;
    if (granted) {
      skip("User " + userId + " already has " + roleId + ".");
    } else if (opts.dryRun) {
      plan("Would grant " + roleId + " to user " + userId + ".");
    } else {
      res = runCmd(userDb, { grantRolesToUser: opts.user, roles: [{ role: opts.role, db: ROLE_DB }] });
      if (!res.ok) { fail(1, "grantRolesToUser failed: " + res.errmsg); }
      ok("Granted " + roleId + " to user " + userId + ".");
    }
  }

  main();
})();
