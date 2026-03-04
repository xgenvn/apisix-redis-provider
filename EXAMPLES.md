# APISIX Redis Provider Examples

This document demonstrates the capabilities of APISIX when using Redis as the configuration provider.

## 1. Setup
Run the following script to initialize the consumers and routes:
```bash
bash setup-examples.sh
```

## 2. Configured Resources

### Consumers
- **jack**:
    - API Key: `auth-one`
    - Rate Limit: 2 requests per minute
- **alice**:
    - API Key: `auth-two`
    - Rate Limit: 1 request per minute

### Route: `/example`
This route demonstrates:
1. **API Key Restriction**: Requires a valid `apikey` header.
2. **Proxy Rewrite**:
    - Rewrites URI to `/get` (upstream `httpbin`).
    - Adds request header `X-Added-Request-Header`.
3. **Response Editing**:
    - Adds response header `X-Added-Response-Header`.
    - Overrides `Server` header.
    - Replaces response body with custom JSON.
4. **Consumer Specific Logic**: The response body includes the authenticated user's name.

## 3. Verification Steps

### Jack (High Limit)
```bash
# 1st request (Success)
curl -i http://127.0.0.1:9080/example -H 'apikey: auth-one'

# 2nd request (Success)
curl -i http://127.0.0.1:9080/example -H 'apikey: auth-one'

# 3rd request (429 Too Many Requests)
curl -i http://127.0.0.1:9080/example -H 'apikey: auth-one'
```

### Alice (Low Limit)
```bash
# 1st request (Success)
curl -i http://127.0.0.1:9080/example -H 'apikey: auth-two'

# 2nd request (429 Too Many Requests)
curl -i http://127.0.0.1:9080/example -H 'apikey: auth-two'
```

### Unauthorized Access
```bash
# No API key (401 Unauthorized)
curl -i http://127.0.0.1:9080/example
```

## 4. Redis Internals
You can verify that APISIX is storing these configurations in Redis:
```bash
docker exec -it apisix-redis-1 redis-cli SCAN 0
```
Expected keys:
- `/apisix/consumers/jack`
- `/apisix/consumers/alice`
- `/apisix/routes/complex-example`
- `/apisix/revision`
