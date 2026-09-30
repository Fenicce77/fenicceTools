var collectionName = "features"; // <--- CAMBIA ESTO

function getType(val) {
    if (val === null) return "Null";
    if (val instanceof ObjectId) return "ObjectId";
    if (val instanceof Date) return "Date";
    if (Array.isArray(val)) return "Array";
    if (typeof val === 'object') return "Object";
    if (typeof val === 'number') return "Number";
    if (typeof val === 'boolean') return "Boolean";
    return typeof val;
}

function mapStructure(doc) {
    var structure = {};
    
    // Ordenar las llaves para que sea legible
    Object.keys(doc).sort().forEach(function(key) {
        var value = doc[key];
        var type = getType(value);

        if (type === "Object") {
            // Si es un objeto, llamamos recursivamente
            structure[key] = {
                type: "Object",
                properties: mapStructure(value)
            };
        } else if (type === "Array") {
            // Si es array, intentamos ver qué tiene dentro (el primer elemento)
            var innerType = value.length > 0 ? getType(value[0]) : "Empty";
            var innerStruct = (innerType === "Object" && value.length > 0) ? mapStructure(value[0]) : innerType;
            
            structure[key] = {
                type: "Array",
                items: innerStruct
            };
        } else {
            // Valor simple
            structure[key] = type;
        }
    });
    return structure;
}

// Tomamos una muestra (ej. último documento insertado o uno aleatorio)
var sampleDoc = db.getCollection(collectionName).findOne({}, {}, {sort: {$natural: -1}});

if (sampleDoc) {
    printjson(mapStructure(sampleDoc));
} else {
    print("La colección está vacía.");
}
