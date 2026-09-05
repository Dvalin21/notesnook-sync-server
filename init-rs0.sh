#!/bin/sh
# Initiate replica set rs0 on first container startup.
# Use notesnook-db hostname so external clients can resolve the replica set member.
mongosh --quiet --eval '
try {
  var s = rs.status();
  if (s.ok === 1) {
    print("RS already initialized, ok=" + s.ok);
  } else {
    throw new Error("RS not healthy: " + JSON.stringify(s));
  }
} catch (e) {
  print("Initiating rs0 on notesnook-db:27017...");
  rs.initiate({
    _id: "rs0",
    members: [{ _id: 0, host: "notesnook-db:27017" }]
  });
  print("rs.initiate() called");
}
print("rs.status():");
printjson(rs.status());
'
