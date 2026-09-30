// MongoDB Playground
// Use Ctrl+Space inside a snippet or a string literal to trigger completions.

// The current database to use.
use("dev_betbuilder_test");

// Find a document in a collection.

db.getCollection('betslips').updateMany(
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

db.getCollection('sport').updateMany(
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

db.getCollection('users').updateMany(
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

db.getCollection('templates').updateMany(
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


db.getCollection('bb-feats').updateMany(
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
