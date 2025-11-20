#!/usr/bin/env bash
set -euo pipefail

echo "[init] Bringing up docker compose services..."
docker compose up -d

echo "[init] Waiting 2s for containers to settle..."
sleep 2

echo "[init] Initiating config server replica set (config_server)..."
docker compose exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [ { _id: 0, host: "configSrv:27017" } ]
});
let i=0;
while (true) {
  const s = rs.status();
  if (s.ok===1 && s.members && s.members.some(m => m.stateStr==="PRIMARY")) { print("[ok] config_server PRIMARY ready"); break; }
  if (i++>90) { throw new Error("config_server RS did not become PRIMARY in time"); }
  sleep(1000);
}
EOF

echo "[init] Initiating shard1 replica set (shard1)..."
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [ { _id: 0, host: "shard1:27018" } ]
});
let i=0;
while (true) {
  const s = rs.status();
  if (s.ok===1 && s.members && s.members.some(m => m.stateStr==="PRIMARY")) { print("[ok] shard1 PRIMARY ready"); break; }
  if (i++>90) { throw new Error("shard1 RS did not become PRIMARY in time"); }
  sleep(1000);
}
EOF

echo "[init] Initiating shard2 replica set (shard2)..."
docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [ { _id: 0, host: "shard2:27019" } ]
});
let i=0;
while (true) {
  const s = rs.status();
  if (s.ok===1 && s.members && s.members.some(m => m.stateStr==="PRIMARY")) { print("[ok] shard2 PRIMARY ready"); break; }
  if (i++>90) { throw new Error("shard2 RS did not become PRIMARY in time"); }
  sleep(1000);
}
EOF

echo "[init] Dropping any stray somedb on shard1 (avoid 'local database exists' conflicts)..."
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
db.dropDatabase()
print("[ok] dropped somedb on shard1 (if existed)")
EOF

echo "[init] Dropping any stray somedb on shard2 (avoid 'local database exists' conflicts)..."
docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
use somedb
db.dropDatabase()
print("[ok] dropped somedb on shard2 (if existed)")
EOF

echo "[init] Adding shard1 via mongos..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use admin
printjson(sh.addShard("shard1/shard1:27018"));
EOF

echo "[init] Adding shard2 via mongos..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use admin
printjson(sh.addShard("shard2/shard2:27019"));
EOF

echo "[init] Enabling sharding for database somedb..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use admin
printjson(sh.enableSharding("somedb"));
EOF

echo "[init] Sharding collection somedb.helloDoc on hashed _id..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use admin
printjson(sh.shardCollection("somedb.helloDoc", { _id: "hashed" }));
EOF

echo "[init] Inserting 1000 documents via mongos with the requested loop..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
print("[ok] inserted 1000 docs; total:", db.helloDoc.countDocuments())
EOF

echo "[init] Checking shard list and distribution..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use admin
print("== listShards ==")
printjson(db.adminCommand({ listShards: 1 }))
use somedb
print("== getShardDistribution (helloDoc) ==")
db.helloDoc.getShardDistribution()
EOF

echo "[init] Done. App URL: http://localhost:8080"
