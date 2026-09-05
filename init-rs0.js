// Initiate replica set rs0 for notesnook on first container startup.
// Safe to run multiple times: rs.status() throws if not a replica set yet,
// rs.initiate() throws if already initiated.
try {
  rs.status();
  // Already a replica set — nothing to do.
} catch (e) {
  // Not initiated yet — initiate as single-member PRIMARY.
  rs.initiate({
    _id: "rs0",
    members: [{ _id: 0, host: "notesnook-db:27017" }]
  });
}
