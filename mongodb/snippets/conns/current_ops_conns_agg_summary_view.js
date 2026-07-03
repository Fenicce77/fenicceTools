// Get aggregated connection information
var connectionSummary = db.currentOp(true).inprog.reduce(function(acc, op) {
    if (op.active && op.desc !== "conn") {
        var user = op.appName || "Unknown";
        var dbName = op.ns ? op.ns.split('.')[0] : "N/A";
        
        if (!acc[user]) {
            acc[user] = {
                totalConnections: 0,
                totalRunningTime: 0,
                operations: {},
                databases: {}
            };
        }
        
        acc[user].totalConnections++;
        acc[user].totalRunningTime += (op.secs_running || 0);
        
        // Count operations by type
        var opType = op.op;
        acc[user].operations[opType] = (acc[user].operations[opType] || 0) + 1;
        
        // Count database usage
        if (dbName !== "N/A") {
            acc[user].databases[dbName] = (acc[user].databases[dbName] || 0) + 1;
        }
    }
    return acc;
}, {});

// Display summary
print("=== CONNECTION SUMMARY ===");
for (var user in connectionSummary) {
    var stats = connectionSummary[user];
    print("\nUser: " + user);
    print("Total Connections: " + stats.totalConnections);
    print("Total Running Time: " + stats.totalRunningTime + " seconds");
    print("Average Time per Connection: " + 
          (stats.totalRunningTime / stats.totalConnections).toFixed(2) + " seconds");
    
    print("Operations: " + JSON.stringify(stats.operations, null, 2));
    print("Databases: " + JSON.stringify(stats.databases, null, 2));
    print("─".repeat(50));
}