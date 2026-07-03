// Find long-running operations (more than 10 seconds)
var longRunningOps = db.currentOp(true).inprog.filter(function(op) {
    return op.secs_running > 10 && op.active;
});

print("=== LONG-RUNNING OPERATIONS (>10 seconds) ===");
print("Count: " + longRunningOps.length);

longRunningOps.forEach(function(op) {
    print("\nLong-running operation detected:");
    print("Running for: " + op.secs_running + " seconds");
    print("Connection ID: " + op.connectionId);
    print("User: " + (op.appName || "Unknown"));
    print("Operation: " + op.op);
    print("Namespace: " + (op.ns || "N/A"));
    print("Client: " + op.client);
});