// MongoDB Playground
// Use Ctrl+Space inside a snippet or a string literal to trigger completions.

// The current database to use.
use("dev_betbuilder_test");

// betslips collection update for adding and populating new fields
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

// sport collection update for adding and populating new fields
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

// user collection update for adding and populating new fields
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

 // templates collection update for adding and populating new fields
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

// bb-feats collection update for adding and populating new fields
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
