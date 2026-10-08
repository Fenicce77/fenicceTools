use admin
db.createRole({
  role: "oplogReader",
  privileges: [
    {
      resource: { db: "local", collection: "oplog.rs" },
      actions: [ "find" ]
    }
  ],
  roles: []
})

db.grantRolesToUser("tu_usuario", [
  { role: "oplogReader", db: "admin" }
])