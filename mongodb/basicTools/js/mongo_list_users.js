/**
 * Script: mongo_list_users.js
 * Description: Lists MongoDB users, authentication databases, assigned/inherited roles,
 *              and authorized target databases across the cluster.
 * Compatibility: mongosh (Linux / macOS) against MongoDB 4.4+ to 8.x
 */

// ANSI Escape Codes (Standard cross-platform terminal formatting)
const COLORS = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  cyan: "\x1b[36m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  magenta: "\x1b[35m",
  gray: "\x1b[90m"
};

function printHelp() {
  console.log(`
${COLORS.bold}${COLORS.cyan}MongoDB User Permissions Audit Tool${COLORS.reset}
${COLORS.gray}Inspects database users, active roles, and authorized target schemas.${COLORS.reset}

${COLORS.bold}USAGE:${COLORS.reset}
  mongosh [connection-options] --file mongo_list_users.js [-- [--json] [--user=<username>] [--auth-db=<db>]]

${COLORS.bold}OPTIONS (passed after '--'):${COLORS.reset}
  ${COLORS.green}--help${COLORS.reset}              Show this documentation and exit.
  ${COLORS.green}--json${COLORS.reset}              Output results strictly in JSON format.
  ${COLORS.green}--user=<name>${COLORS.reset}       Target a specific username (enables deep privilege resolution).
  ${COLORS.green}--auth-db=<db>${COLORS.reset}      Authentication database for --user (Defaults to 'admin').

${COLORS.bold}REQUIRED PRIVILEGES:${COLORS.reset}
  - Role: ${COLORS.yellow}userAdminAnyDatabase${COLORS.reset}, ${COLORS.yellow}userAdmin${COLORS.reset} or ${COLORS.yellow}root${COLORS.reset}.
  - Action: ${COLORS.yellow}viewUser${COLORS.reset} and ${COLORS.yellow}viewRole${COLORS.reset} on relevant databases.

${COLORS.bold}EXAMPLES:${COLORS.reset}
  ${COLORS.gray}# 1. Cluster-wide audit:${COLORS.reset}
  mongosh "mongodb://rmateos:SecretPass@127.0.0.1:27017/admin" --file mongo_list_users.js

  ${COLORS.gray}# 2. Targeted audit for specific user with deep privilege inspection:${COLORS.reset}
  mongosh "mongodb://rmateos:SecretPass@127.0.0.1:27017/admin" --file mongo_list_users.js -- --user=rmateos --auth-db=admin

  ${COLORS.gray}# 3. Export entire audit to JSON for pipeline processing:${COLORS.reset}
  mongosh "mongodb://rmateos:SecretPass@127.0.0.1:27017/admin" --file mongo_list_users.js -- --json | jq .
`);
}

function parseCliArgs() {
  const options = {
    help: false,
    json: false,
    userFilter: null,
    authDb: "admin"
  };

  const args = (typeof process !== "undefined" && process.argv) ? process.argv : [];

  for (const arg of args) {
    if (arg === "--help" || arg === "-h") {
      options.help = true;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg.startsWith("--user=")) {
      options.userFilter = arg.split("=")[1];
    } else if (arg.startsWith("--auth-db=")) {
      options.authDb = arg.split("=")[1];
    }
  }

  return options;
}

function resolveUserDatabases(userDoc, showPrivilegesEnabled) {
  const targetDbs = new Set();
  const activeRoles = userDoc.inheritedRoles && userDoc.inheritedRoles.length > 0
    ? userDoc.inheritedRoles
    : (userDoc.roles || []);

  const anyDatabaseRoles = new Set([
    "readAnyDatabase",
    "readWriteAnyDatabase",
    "userAdminAnyDatabase",
    "dbAdminAnyDatabase",
    "root",
    "clusterAdmin"
  ]);

  // 1. Resolve databases via assigned/inherited roles
  activeRoles.forEach(r => {
    if (anyDatabaseRoles.has(r.role)) {
      targetDbs.add("* (all databases)");
    } else if (r.db) {
      targetDbs.add(r.db);
    }
  });

  // 2. Resolve via privilege resources if available (only populated when showPrivileges: true)
  if (showPrivilegesEnabled && Array.isArray(userDoc.inheritedPrivileges)) {
    userDoc.inheritedPrivileges.forEach(p => {
      if (p.resource) {
        if (p.resource.cluster) {
          targetDbs.add("cluster");
        } else if (p.resource.db !== undefined) {
          targetDbs.add(p.resource.db === "" ? "* (all databases)" : p.resource.db);
        }
      }
    });
  }

  return {
    user: userDoc.user,
    authenticationDatabase: userDoc.db,
    roles: activeRoles.map(r => `${r.role}@${r.db}`),
    authorizedDatabases: Array.from(targetDbs).sort()
  };
}

function runAudit() {
  const options = parseCliArgs();

  if (options.help) {
    printHelp();
    return;
  }

  const adminDb = db.getSiblingDB("admin");
  let commandPayload = {};
  let showPrivileges = false;

  if (options.userFilter) {
    // Single user query allows exact privilege resolution
    commandPayload = {
      usersInfo: {
        user: options.userFilter,
        db: options.authDb
      },
      showPrivileges: true
    };
    showPrivileges = true;
  } else {
    // Global scan: omit showPrivileges to prevent engine assertion failure
    commandPayload = {
      usersInfo: { forAllDBs: true }
    };
    showPrivileges = false;
  }

  let result;
  try {
    result = adminDb.runCommand(commandPayload);
  } catch (err) {
    console.error(`${COLORS.red}[ERROR] Failed executing usersInfo command: ${err.message}${COLORS.reset}`);
    return;
  }

  if (!result.ok) {
    console.error(`${COLORS.red}[ERROR] Database returned: ${result.errmsg}${COLORS.reset}`);
    return;
  }

  if (!result.users || result.users.length === 0) {
    if (options.json) {
      console.log(JSON.stringify([], null, 2));
    } else {
      console.log(`${COLORS.yellow}[WARN] No users found matching specified criteria.${COLORS.reset}`);
    }
    return;
  }

  const parsedUsers = result.users.map(u => resolveUserDatabases(u, showPrivileges));

  if (options.json) {
    console.log(JSON.stringify(parsedUsers, null, 2));
    return;
  }

  console.log(`\n${COLORS.bold}${COLORS.cyan}=== MONGODB USER PRIVILEGES AUDIT ===${COLORS.reset}`);
  console.log(`${COLORS.gray}Total users retrieved: ${parsedUsers.length}${COLORS.reset}\n`);

  parsedUsers.forEach((u, idx) => {
    console.log(`${COLORS.bold}[${idx + 1}] User:${COLORS.reset} ${COLORS.green}${u.user}${COLORS.reset} (AuthDB: ${COLORS.yellow}${u.authenticationDatabase}${COLORS.reset})`);
    console.log(`    ${COLORS.bold}Roles:${COLORS.reset}      ${u.roles.length > 0 ? u.roles.join(", ") : `${COLORS.gray}None${COLORS.reset}`}`);
    console.log(`    ${COLORS.bold}Databases:${COLORS.reset}  ${COLORS.magenta}${u.authorizedDatabases.join(", ")}${COLORS.reset}`);
    console.log(`${COLORS.gray}------------------------------------------------------------${COLORS.reset}`);
  });
}

runAudit();