// Get all current operations/connections
var currentOps = db.currentOp(true);

// Filter to show only active connections (excluding idle/system ones)
var activeConnections = currentOps.inprog.filter(function(op) {
    return op.active && 
           op.desc !== "conn" && 
           op.op !== "none" && 
           !op.client.startsWith("127.0.0.1"); // Exclude local connections if desired
});

// Display detailed information for each connection
print("=== CURRENT ACTIVE CONNECTIONS ===");
print("Total active connections: " + activeConnections.length);
print("==================================");

activeConnections.forEach(function(conn, index) {
    print("\n--- Connection " + (index + 1) + " ---");
    print("Connection ID: " + conn.connectionId);
    print("Client: " + conn.client);
    print("User: " + (conn.appName || "Unknown"));
    print("Database: " + (conn.ns || "N/A"));
    print("Operation: " + conn.op);
    print("Command: " + JSON.stringify(conn.command, null, 2));
    print("Active: " + conn.active);
    print("Running Time: " + (conn.secs_running || 0) + " seconds");
    print("Microseconds Running: " + (conn.microsecs_running || 0));
    
    if (conn.planSummary) {
        print("Plan Summary: " + JSON.stringify(conn.planSummary));
    }
});