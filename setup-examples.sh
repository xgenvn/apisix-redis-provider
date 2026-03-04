#!/bin/bash

# Configuration
ADMIN_URL="http://127.0.0.1:9180/apisix/admin"
ADMIN_KEY="edd1c9f0985e76a2"

echo "Setting up APISIX Redis Configuration Provider Examples..."

# 1. Create Consumer 'jack' (2 requests per minute)
echo "Creating consumer 'jack'..."
curl -s -X PUT "$ADMIN_URL/consumers" \
-H "X-API-KEY: $ADMIN_KEY" \
-d '{
    "username": "jack",
    "plugins": {
        "key-auth": {
            "key": "auth-one"
        },
        "limit-count": {
            "count": 2,
            "time_window": 60,
            "rejected_code": 429,
            "key_type": "var",
            "key": "consumer_name"
        }
    }
}'

# 2. Create Consumer 'alice' (1 request per minute)
echo "Creating consumer 'alice'..."
curl -s -X PUT "$ADMIN_URL/consumers" \
-H "X-API-KEY: $ADMIN_KEY" \
-d '{
    "username": "alice",
    "plugins": {
        "key-auth": {
            "key": "auth-two"
        },
        "limit-count": {
            "count": 1,
            "time_window": 60,
            "rejected_code": 429,
            "key_type": "var",
            "key": "consumer_name"
        }
    }
}'

# 3. Create Complex Route '/example'
echo "Creating complex route '/example'..."
curl -s -X PUT "$ADMIN_URL/routes/complex-example" \
-H "X-API-KEY: $ADMIN_KEY" \
-d '{
    "uri": "/example",
    "plugins": {
        "key-auth": {},
        "proxy-rewrite": {
            "uri": "/get",
            "headers": {
                "X-Added-Request-Header": "apisix-is-awesome"
            }
        },
        "response-rewrite": {
            "headers": {
                "X-Added-Response-Header": "apisix-processed",
                "Server": "APISIX-Enhanced-Server"
            },
            "body": "{\"message\": \"Response edited by APISIX\", \"original_status\": \"$status\", \"user\": \"$consumer_name\"}"
        }
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": {
            "httpbin:8080": 1
        }
    }
}'

echo "Setup complete!"
