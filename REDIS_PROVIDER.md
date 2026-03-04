# Redis Configuration Provider Plan

This document outlines the plan to add Redis as a configuration provider to Apache APISIX, providing an alternative to etcd.

## 1. Configuration Changes
Update `conf/config-default.yaml` to support Redis deployment options:
```yaml
deployment:
  config_provider: redis
  redis:
    host:
      - 127.0.0.1
    port: 6379
    password: ~
    database: 0
    prefix: /apisix
    cluster_nodes: # For Redis Cluster
      - 127.0.0.1:6379
```

## 2. Data Plane: `apisix/core/config_redis.lua`
This module will handle configuration synchronization for APISIX workers.
- **Initial Load**: Use the Redis `SCAN` command to retrieve all keys under the configured prefix during startup.
- **Watch Mechanism**: Since Redis lacks a native "watch" on prefixes, use **Redis Pub/Sub**.
    - Workers subscribe to a channel (e.g., `${prefix}/config_events`).
    - When a message (e.g., `{"key": "routes/1", "action": "set"}`) is received, the worker fetches the updated key and refreshes its local cache.
- **Consistency**: Maintain a global `${prefix}/revision` key in Redis that increments on every write to simulate etcd's revision system.

## 3. Control Plane: `apisix/core/redis_store.lua`
Implement a storage interface compatible with `apisix/core/etcd.lua` to minimize changes to the Admin API.
- **Operations**: Implement `get`, `set`, `delete`, `push`, and `atomic_set`.
- **Atomic Updates**: Use Redis **Lua scripts** or `WATCH/MULTI/EXEC` to implement `atomic_set` (Compare-and-Swap) for safe concurrent updates.
- **Notifications**: Every write operation must `PUBLISH` an event to the notification channel to alert workers.

## 4. Core Integration: `apisix/core.lua`
Modify `apisix/core.lua` to export the appropriate storage module based on the `config_provider` setting:
```lua
local config_provider = local_conf.deployment.config_provider or "etcd"
if config_provider == "redis" then
    _M.config_store = require("apisix.core.redis_store")
else
    _M.config_store = require("apisix.core.etcd")
end
-- Maintain backward compatibility for Admin API resources
_M.etcd = _M.config_store
```

## 5. Implementation Steps
1.  **Utilities**: Enhance `apisix/utils/redis.lua` to support persistent connections for Pub/Sub.
2.  **Storage Layer**: Build `apisix/core/redis_store.lua` and verify with unit tests.
3.  **Sync Layer**: Build `apisix/core/config_redis.lua` and implement the background timer loop for Pub/Sub.
4.  **Admin API**: Verify `apisix/admin/resource.lua` works seamlessly with the new storage layer.
## 6. Running and Verification (Docker Compose)
A `docker-compose.redis-provider.yaml` and `apisix_redis_conf.yaml` are provided to run APISIX with the Redis configuration provider.

1. **Start the environment**:
   ```bash
   docker-compose -f docker-compose.redis-provider.yaml up -d
   ```

2. **Verify Admin API works with Redis**:
   ```bash
   # Create a route
   curl http://127.0.0.1:9180/apisix/admin/routes/1 \
   -H 'X-API-KEY: edd1c9f0985e76a2' -X PUT \
   -d '{"uri":"/get","upstream":{"type":"roundrobin","nodes":{"httpbin:8080":1}}}'
   ```

3. **Verify Data Plane synchronization**:
   ```bash
   # Access the route through APISIX
   curl http://127.0.0.1:9080/get
   ```

4. **Verify Redis content**:
   ```bash
   docker exec -it apisix-redis-1 redis-cli SCAN 0
   docker exec -it apisix-redis-1 redis-cli GET /apisix/routes/1
   ```
