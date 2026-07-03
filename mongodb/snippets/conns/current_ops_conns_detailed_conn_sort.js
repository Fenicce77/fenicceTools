// Get and sort connections by running time
var connections = db.currentOp(true).inprog
    .filter(function(op) {
        return op.active && op.desc !== "conn" && op.secs_running !== undefined;
    })
    .sort(function(a, b) {
        return (b.secs_running || 0) - (a.secs_running || 0);
    });

print("=== CONNECTIONS SORTED BY RUNNING TIME ===");
connections.forEach(function(conn, index) {
    print("\n#" + (index + 1) + " - " + (conn.secs_running || 0) + "s");
    print("Connection ID: " + conn.connectionId);
    print("Client: " + conn.client);
    print("User: " + (conn.appName || "Unknown"));
    print("Database: " + (conn.ns || "N/A"));
    print("Operation: " + conn.op);
    print("Running Time: " + (conn.secs_running || 0) + " seconds");
    print("Active: " + conn.active);
    
    if (conn.command) {
        print("Command Type: " + Object.keys(conn.command)[0]);
    }
});