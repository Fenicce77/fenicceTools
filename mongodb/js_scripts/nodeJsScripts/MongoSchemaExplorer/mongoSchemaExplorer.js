const { MongoClient } = require('mongodb');
// import { MongoClient } from 'mongodb';
// import connect from './dbConnection.mjs';
// Configuration: connection settings come from the environment, never from this file.
//   MONGO_URI            full connection string WITHOUT password (credentials are added below), or
//   MONGO_HOSTS          "host1:27017,host2:27017" + MONGO_REPLICA_SET (optional)
//   MONGO_USER           user name (optional; no auth when empty)
//   MONGO_PASSWORD_ENV   name of the variable holding the password (default: MONGO_PASSWORD)
//   MONGO_AUTH_SOURCE    authentication database (default: admin)
//   MONGO_DB / MONGO_COLLECTION   target namespace (default: dev_betbuilder_ug.users)
// Example:
//   read -rs MONGO_PASSWORD && export MONGO_PASSWORD
//   MONGO_HOSTS="node01:27017,node02:27017,node03:27017" MONGO_REPLICA_SET="rsName" \
//   MONGO_USER="mongoAdmin" node mongoSchemaExplorer.js
const C_RED = '\x1b[91m', C_YEL = '\x1b[93m', C_RST = '\x1b[0m';

function usage(code) {
    console.log(`${C_YEL}Usage:${C_RST} [MONGO_URI=... | MONGO_HOSTS=... [MONGO_REPLICA_SET=...]] [MONGO_USER=...] node mongoSchemaExplorer.js`);
    console.log('Password is read from $MONGO_PASSWORD (or the variable named by $MONGO_PASSWORD_ENV); see the header of this file.');
    process.exit(code);
}

function buildUri() {
    const env = process.env;
    if (process.argv.includes('-h') || process.argv.includes('--help')) usage(0);
    let uri = env.MONGO_URI || '';
    if (!uri) {
        if (!env.MONGO_HOSTS) {
            console.error(`${C_RED}Error: set MONGO_URI or MONGO_HOSTS${C_RST}`);
            usage(2);
        }
        const params = [];
        if (env.MONGO_REPLICA_SET) params.push(`replicaSet=${encodeURIComponent(env.MONGO_REPLICA_SET)}`);
        uri = `mongodb://${env.MONGO_HOSTS}/${params.length ? '?' + params.join('&') : ''}`;
    }
    if (!env.MONGO_USER) return { uri, options: {} };
    const pwdVar = env.MONGO_PASSWORD_ENV || 'MONGO_PASSWORD';
    const password = env[pwdVar];
    if (!password) {
        console.error(`${C_RED}Error: MONGO_USER is set but ${pwdVar} is empty or not set${C_RST}`);
        usage(2);
    }
    // Credentials go through the driver options, not the connection string.
    return { uri, options: { auth: { username: env.MONGO_USER, password }, authSource: env.MONGO_AUTH_SOURCE || 'admin' } };
}

const { uri, options: clientOptions } = buildUri();
const dbName = process.env.MONGO_DB || "dev_betbuilder_ug";
const collectionName = process.env.MONGO_COLLECTION || "users";

// Función recursiva para detectar tipos
function getType(val) {
    if (val === null) return 'Null';
    if (Array.isArray(val)) return 'Array';
    if (val instanceof Date) return 'Date';
    if (val && typeof val === 'object' && val._bsontype === 'ObjectID') return 'ObjectId';
    return typeof val; // 'string', 'number', 'boolean', 'object'
}

// Función recursiva para fusionar esquemas
function mergeSchema(currentSchema, doc) {
    for (const key in doc) {
        const type = getType(doc[key]);
        
        // Inicializar si no existe
        if (!currentSchema[key]) {
            currentSchema[key] = { types: new Set() };
        }
        
        // Añadir tipo encontrado
        currentSchema[key].types.add(type);

        // Si es un objeto anidado, recursión
        if (type === 'object') {
            if (!currentSchema[key].nested) currentSchema[key].nested = {};
            mergeSchema(currentSchema[key].nested, doc[key]);
        }
        
        // Si es un array, inspeccionar primer elemento (simplificado)
        if (type === 'Array' && doc[key].length > 0) {
            const innerType = getType(doc[key][0]);
            if (!currentSchema[key].arrayItemType) currentSchema[key].arrayItemType = new Set();
            currentSchema[key].arrayItemType.add(innerType);
            
            if (innerType === 'object') {
                if (!currentSchema[key].arrayNested) currentSchema[key].arrayNested = {};
                // Analizar muestra de elementos del array
                doc[key].forEach(item => {
                    if (typeof item === 'object') mergeSchema(currentSchema[key].arrayNested, item);
                });
            }
        }
    }
}

async function run() {
    const client = new MongoClient(uri, clientOptions);
    try {
        await client.connect();
        const col = client.db(dbName).collection(collectionName);
        
        // Usamos una muestra para rendimiento (ej: 1000 docs)
        // Quita .limit(1000) para escanear todo (lento en DBs grandes)
        const cursor = col.find().limit(1000); 
        
        const finalSchema = {};

        while(await cursor.hasNext()) {
            const doc = await cursor.next();
            mergeSchema(finalSchema, doc);
        }

        // Convertir Sets a Arrays para JSON stringify
        const jsonReplacer = (key, value) => {
            if (value instanceof Set) return [...value];
            return value;
        };

        console.log(JSON.stringify(finalSchema, jsonReplacer, 2));

    } finally {
        await client.close();
    }
}

run().catch(console.dir);