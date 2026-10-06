// Create the role for Percona Backup for MongoDB
db.getSiblingDB("admin").createRole(
{ 
  "role": "pbmAnyAction",
  "privileges": [
    { 
      "resource": { "anyResource": true },
      "actions": [ "anyAction" ]
    }],
    "roles": []
});

// Create the user for Percona Backup for MongoDB
db.getSiblingDB("admin").createUser({
  user: "pbmuser",
  pwd: passwordPrompt(),
  roles: [{ role : "backup", db: "admin" },
      { role : "clusterAdmin", db: "admin" },
      { role : "clusterMonitor", db: "admin"},
      { role : "readWriteAnyDatabase", db: "admin" },
      { role : "userAdminAnyDatabase", db: "admin" },
      { role : "restore", db: "admin" }]
});
