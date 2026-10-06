/*
 * pbmuser.create.js - Create or update the Percona Backup for MongoDB (PBM)
 * user and its "pbmAnyAction" role, with exactly the roles PBM documents:
 *   readWrite (admin), backup, clusterMonitor, restore, pbmAnyAction
 * https://docs.percona.com/percona-backup-mongodb/install/configure-authentication.html
 *
 * Run it MANUALLY with mongosh, once per replica set, connected to the
 * PRIMARY as a user that can manage users and roles (users and roles
 * replicate to the other members). Safe to run again:
 *   - the role and the user's roles are set to the documented ones (extra
 *     roles such as clusterAdmin or userAdminAnyDatabase are removed);
 *   - an existing user keeps its password unless PBM_ROTATE_PASSWORD=1, so
 *     running pbm-agents are not locked out.
 *
 * When a password is set (new user or rotation) it is generated (default) or
 * typed twice, then SHOWN ON SCREEN and saved to
 *   ~/.pbm-backup/<user>.<replset>.<UTC timestamp>.env   (dir 0700, file 0600)
 * on the machine where mongosh runs, together with ready-to-use
 * PBM_MONGODB_URI lines. That file is a secret: copy what you need to
 * /etc/sysconfig/pbm-conf and /etc/sysconfig/pbm-agent (or your secret
 * store) and delete it.
 *
 * Requires mongosh (uses Node.js crypto/fs; the legacy "mongo" shell cannot
 * run it).
 *
 * Environment variables (mongosh scripts take no arguments):
 *   PBM_USER             user name                            (default pbmuser)
 *   PBM_PASSWORD_MODE    generate | prompt                    (default generate)
 *   PBM_ROTATE_PASSWORD  1 = set a new password on an existing user
 *   PBM_SECRET_DIR       where the .env file is written       (default ~/.pbm-backup)
 *   PBM_HELP             1 = print this help and exit
 *
 * Exit codes: 0 done, 1 error (not primary, MongoDB error, file not written),
 *             2 usage error (bad variable, legacy shell).
 *
 * Examples:
 *   # New user, generated password
 *   mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js
 *
 *   # New user, password typed by hand
 *   PBM_PASSWORD_MODE=prompt mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js
 *
 *   # Fix the roles of an existing user, keep its password
 *   mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js
 *
 *   # Rotate the password (then update pbm-conf / pbm-agent on EVERY member)
 *   PBM_ROTATE_PASSWORD=1 mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js
 */

/* global db, quit, passwordPrompt, require, process */

(function main() {
    'use strict';

    // ---------------------------------------------------------------------
    // Environment
    // ---------------------------------------------------------------------
    if (typeof require !== 'function' || typeof process !== 'object') {
        print('[ERROR] This script needs mongosh (Node.js runtime). The legacy "mongo" shell is not supported.');
        quit(2);
    }
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    const crypto = require('crypto');
    const env = process.env;

    // Test hook (tests/pbmuser.test.sh): a fake admin database and prompt.
    const T = (typeof globalThis.__pbmUserTest === 'object') ? globalThis.__pbmUserTest : null;

    const color = (process.stdout && process.stdout.isTTY && !env.NO_COLOR);
    const C = {
        red: color ? '\x1b[31m' : '', grn: color ? '\x1b[32m' : '', yel: color ? '\x1b[33m' : '',
        blu: color ? '\x1b[34m' : '', bld: color ? '\x1b[1m' : '', off: color ? '\x1b[0m' : '',
    };
    const info = (m) => print(`${C.blu}[INFO]${C.off} ${m}`);
    const ok = (m) => print(`${C.grn}[OK]${C.off} ${m}`);
    const warn = (m) => print(`${C.yel}[WARN]${C.off} ${m}`);
    const fail = (m, code) => { print(`${C.red}[ERROR]${C.off} ${m}`); quit(code === undefined ? 1 : code); };

    if (env.PBM_HELP === '1') {
        // Print the header comment of this file.
        const src = (typeof __filename === 'string' && fs.existsSync(__filename)) ? fs.readFileSync(__filename, 'utf8') : '';
        const head = src.split('*/')[0].replace(/^\/\*\s?/, '').split('\n').map((l) => l.replace(/^ \* ?/, ''));
        print(head.length > 1 ? head.join('\n') : 'See the header of pbmuser.create.js for usage.');
        quit(0);
    }

    const USER = env.PBM_USER || 'pbmuser';
    const MODE = (env.PBM_PASSWORD_MODE || 'generate').toLowerCase();
    const ROTATE = env.PBM_ROTATE_PASSWORD === '1';
    const SECRET_DIR = env.PBM_SECRET_DIR || path.join(os.homedir(), '.pbm-backup');
    if (!/^[A-Za-z0-9._-]+$/.test(USER)) {
        fail(`PBM_USER '${USER}' is not valid (letters, digits, . _ -)`, 2);
    }
    if (MODE !== 'generate' && MODE !== 'prompt') {
        fail(`PBM_PASSWORD_MODE must be 'generate' or 'prompt' (got '${MODE}')`, 2);
    }

    // ---------------------------------------------------------------------
    // What PBM needs (PBM documentation, configure-authentication)
    // ---------------------------------------------------------------------
    const ROLE = 'pbmAnyAction';
    const ROLE_PRIVILEGES = [{ resource: { anyResource: true }, actions: ['anyAction'] }];
    const USER_ROLES = [
        { role: 'readWrite', db: 'admin' },
        { role: 'backup', db: 'admin' },
        { role: 'clusterMonitor', db: 'admin' },
        { role: 'restore', db: 'admin' },
        { role: ROLE, db: 'admin' },
    ];
    const WC = { w: 'majority', wtimeout: 30000 };

    const adminDb = T ? T.adminDb : db.getSiblingDB('admin');
    const askPassword = T && T.passwordPrompt ? T.passwordPrompt : passwordPrompt;

    const roleKey = (r) => `${r.role}@${r.db}`;
    const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

    // ---------------------------------------------------------------------
    // Must be the primary
    // ---------------------------------------------------------------------
    let hello;
    try {
        hello = adminDb.runCommand({ hello: 1 });
    } catch (e) {
        fail(`Cannot run 'hello': ${e.message || e}`);
    }
    if (!hello.isWritablePrimary) {
        fail(`Not connected to the PRIMARY${hello.primary ? ` (primary is ${hello.primary})` : ''}. Connect with ?replicaSet=<name> or to the primary host`);
    }
    const RS = hello.setName || 'standalone';
    const HOSTS = [...(hello.hosts || []), ...(hello.passives || [])];
    if (!hello.setName) {
        warn('This server is not part of a replica set');
    }
    info(`Replica set ${RS}, primary ${hello.me || '?'}, members: ${HOSTS.join(', ') || '?'}`);

    // ---------------------------------------------------------------------
    // Role pbmAnyAction
    // ---------------------------------------------------------------------
    try {
        const role = adminDb.getRole(ROLE, { showPrivileges: true });
        if (!role) {
            adminDb.createRole({ role: ROLE, privileges: ROLE_PRIVILEGES, roles: [] }, WC);
            ok(`Role ${ROLE} created`);
        } else {
            const current = JSON.stringify((role.privileges || []).map((p) => ({ resource: p.resource, actions: [...p.actions].sort() })));
            if (current !== JSON.stringify(ROLE_PRIVILEGES) || (role.roles || []).length > 0) {
                adminDb.updateRole(ROLE, { privileges: ROLE_PRIVILEGES, roles: [] }, WC);
                ok(`Role ${ROLE} updated to anyAction on anyResource`);
            } else {
                ok(`Role ${ROLE} already correct`);
            }
        }
    } catch (e) {
        fail(`Role ${ROLE}: ${e.message || e}`);
    }

    // ---------------------------------------------------------------------
    // Password helpers
    // ---------------------------------------------------------------------
    function generatePassword(len) {
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        let out = '';
        for (let i = 0; i < len; i++) {
            out += alphabet[crypto.randomInt(alphabet.length)];
        }
        return out;
    }

    function obtainPassword() {
        if (MODE === 'generate') {
            info('Generating a random 32-character password');
            return generatePassword(32);
        }
        print(`Password for ${USER} (min. 12 characters):`);
        const p1 = askPassword();
        print('Repeat the password:');
        const p2 = askPassword();
        if (p1 !== p2) {
            fail('Passwords do not match. Nothing changed for the user', 2);
        }
        if (typeof p1 !== 'string' || p1.length < 12) {
            fail('Password too short (min. 12 characters). Nothing changed for the user', 2);
        }
        return p1;
    }

    // ---------------------------------------------------------------------
    // User
    // ---------------------------------------------------------------------
    let password = null;
    try {
        const user = adminDb.getUser(USER);
        if (!user) {
            password = obtainPassword();
            adminDb.createUser({ user: USER, pwd: password, roles: USER_ROLES }, WC);
            ok(`User ${USER} created with roles ${USER_ROLES.map(roleKey).join(', ')}`);
        } else {
            const have = (user.roles || []).map(roleKey);
            const want = USER_ROLES.map(roleKey);
            if (!sameSet(have, want)) {
                adminDb.updateUser(USER, { roles: USER_ROLES }, WC);
                const removed = have.filter((r) => !want.includes(r));
                const added = want.filter((r) => !have.includes(r));
                ok(`User ${USER} roles fixed${added.length ? `; added: ${added.join(', ')}` : ''}${removed.length ? `; removed: ${removed.join(', ')}` : ''}`);
            } else {
                ok(`User ${USER} already has exactly the PBM roles`);
            }
            if (ROTATE) {
                password = obtainPassword();
                adminDb.updateUser(USER, { pwd: password }, WC);
                ok(`Password of ${USER} changed`);
                warn('Update PBM_MONGODB_URI in /etc/sysconfig/pbm-conf and pbm-agent on EVERY member and restart pbm-agent');
            } else {
                info('Existing user: password NOT changed (set PBM_ROTATE_PASSWORD=1 to rotate it)');
            }
        }
    } catch (e) {
        fail(`User ${USER}: ${e.message || e}`);
    }

    if (password === null) {
        ok('Done. No password was set, so nothing is shown or saved');
        quit(0);
    }

    // ---------------------------------------------------------------------
    // Show and save the password (shown first: a file error cannot lose it)
    // ---------------------------------------------------------------------
    const enc = encodeURIComponent(password);
    const seed = HOSTS.length ? HOSTS.join(',') : (hello.me || 'localhost:27017');
    const rsParam = hello.setName ? `&replicaSet=${encodeURIComponent(hello.setName)}` : '';
    const cliUri = `mongodb://${USER}:${enc}@${seed}/?authSource=admin${rsParam}`;

    print('');
    print(`${C.bld}${C.yel}==================== PBM USER PASSWORD (plain text) ====================${C.off}`);
    print(`  Replica set : ${RS}`);
    print(`  User        : ${USER}`);
    print(`  Password    : ${password}`);
    print(`${C.bld}${C.yel}=========================================================================${C.off}`);
    print('');

    const ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const file = path.join(SECRET_DIR, `${USER}.${RS}.${ts}.env`);
    const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
    const lines = [
        `# PBM credentials for replica set ${RS} - ${new Date().toISOString()} - pbmuser.create.js`,
        '# SECRET (mode 0600): copy what you need, then delete this file.',
        `PBM_USER=${shq(USER)}`,
        `PBM_PASSWORD=${shq(password)}`,
        '',
        '# /etc/sysconfig/pbm-conf (pbm CLI and pbm-backup), same line on every member:',
        `PBM_MONGODB_URI="${cliUri}"`,
        '',
        '# /etc/sysconfig/pbm-agent: each pbm-agent connects to its OWN member:',
    ];
    for (const h of (HOSTS.length ? HOSTS : [seed])) {
        lines.push(`#   ${h}:`);
        lines.push(`#   PBM_MONGODB_URI="mongodb://${USER}:${enc}@${h}/?authSource=admin"`);
    }
    try {
        fs.mkdirSync(SECRET_DIR, { recursive: true, mode: 0o700 });
        try { fs.chmodSync(SECRET_DIR, 0o700); } catch (e) { warn(`Cannot set mode 0700 on ${SECRET_DIR}: ${e.message}`); }
        fs.writeFileSync(file, `${lines.join('\n')}\n`, { mode: 0o600, flag: 'wx' });
        fs.chmodSync(file, 0o600);
    } catch (e) {
        fail(`Password set in MongoDB but the file could not be written (${e.message}). Copy the password shown above now`);
    }
    ok(`Password saved to: ${C.bld}${file}${C.off} (mode 0600)`);
    warn('This file and your terminal scrollback contain the password: move it to its final place and delete the file');
    quit(0);
}());
