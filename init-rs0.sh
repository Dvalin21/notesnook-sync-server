#!/bin/sh
# Initiate replica set rs0 on first container startup.
# Run from inside the MongoDB container. Use localhost because the
# mongod process bound to 0.0.0.0 authenticates the replica set member
# by the address the client uses to connect, and "localhost" (127.0.0.1)
# always maps to this node.
mongosh --quiet --eval '
try {
  var s = rs.status();
  if (s.ok === 1) {
    print("RS already initialized, ok=" + s.ok);
  } else {
    throw new Error("RS not healthy: " + JSON.stringify(s));
  }
} catch (e) {
  print("Initiating rs0 on localhost:27017...");
  rs.initiate({
    _id: "rs0",
    members: [{ _id: 0, host: "localhost:27017" }]
  });
  print("rs.initiate() called");
}
print("rs.status():");
printjson(rs.status());
'
