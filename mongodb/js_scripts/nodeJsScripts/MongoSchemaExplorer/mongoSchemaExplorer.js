const { MongoClient } = require('mongodb');
// import { MongoClient } from 'mongodb';
// import connect from './dbConnection.mjs';
// mongodb://mongoAdmin:tAvgBJTFY8EVBKf0SL3GEQ==@devel-gcssmongodb01-node01:27017,devel-gcssmongodb01-node02:27017,devel-gcssmongodb01-node03:27017/admin?authSource=admin&replicaSet=develrsgcss
// Configuración
const monoguser =  "mongoAdmin"
const monogpass =  "tAvgBJTFY8EVBKf0SL3GEQ=="
const uri = "mongodb://mongoAdmin:tAvgBJTFY8EVBKf0SL3GEQ==@devel-gcssmongodb01-node01:27017,devel-gcssmongodb01-node02:27017,devel-gcssmongodb01-node03:27017/admin?authSource=admin&replicaSet=develrsgcss";

const dbName = "dev_betbuilder_ug";
const collectionName = "users";

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
    const client = new MongoClient(uri);
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