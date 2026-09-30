// MongoDB Playground
// Use Ctrl+Space inside a snippet or a string literal to trigger completions.

// The current database to use.
use("sbtest");

// sport collection update for adding and populating new fields

db.getCollection('sbtest1').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest2').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest3').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest4').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest5').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest6').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);

db.getCollection('sbtest7').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);
/*
db.getCollection('sbtest8').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);
db.getCollection('sbtest9').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);
db.getCollection('sbtest10').updateMany(
    { created_at: { $exists: false } , modified_at: { $exists: false }},
    [
        {
            $addFields: {
                created_at: { $toDate: "$_id" },
                modified_at: { $toDate: "$_id" }
            }
        }
    ]
);


db.sbtest1.dropIndex( "tt_idx_createdAt");
db.sbtest2.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest3.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest4.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest5.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest6.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest7.dropIndex({"created_at" : 1 },{ name : "tt_idx_createdAt" , expireAfterSeconds: 600});

// db.sbtest1.dropIndex({ name : 'modified_at_1'});
//db.sbtest1.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest2.dropIndex('modified_at_1');
//db.sbtest2.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest3.dropIndex('modified_at_1');
db.sbtest3.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest4.dropIndex('modified_at_1');
db.sbtest4.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest5.dropIndex('modified_at_1');
db.sbtest5.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest6.dropIndex('modified_at_1');
db.sbtest6.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest7.dropIndex('modified_at_1');
db.sbtest7.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});

db.sbtest1.dropIndex( "tt_idx_createdAt");
db.sbtest2.dropIndex( "tt_idx_createdAt");
db.sbtest3.dropIndex( "tt_idx_createdAt");
db.sbtest4.dropIndex( "tt_idx_createdAt");
db.sbtest5.dropIndex( "tt_idx_createdAt");
db.sbtest6.dropIndex( "tt_idx_createdAt");
db.sbtest7.dropIndex( "tt_idx_createdAt");
db.sbtest1.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest2.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest3.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest4.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest5.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest6.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
db.sbtest7.createIndex({"created_at" : 1 },{ name : "ttl_idx_createdAt" , expireAfterSeconds: 600});
*/


db.sbtest2.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest3.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest4.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest5.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest6.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});
db.sbtest7.createIndex({ modified_at: 1 },{name : "idx_modifiedAt"});