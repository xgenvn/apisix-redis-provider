--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local redis_cli     = require("apisix.utils.redis")
local fetch_local_conf  = require("apisix.core.config_local").local_conf
local json          = require("apisix.core.json")
local log           = require("apisix.core.log")
local try_read_attr = require("apisix.core.table").try_read_attr
local clone_tab     = require("table.clone")
local ipairs        = ipairs
local pairs         = pairs
local type          = type
local tonumber      = tonumber
local tostring      = tostring
local ngx_get_phase  = ngx.get_phase

local _M = {}

local function get_redis_conf()
    local local_conf, err = fetch_local_conf()
    if not local_conf then
        return nil, err
    end

    local redis_conf = clone_tab(local_conf.deployment.redis)
    return redis_conf
end

local function get_redis_cli()
    local redis_conf, err = get_redis_conf()
    if not redis_conf then
        return nil, nil, err
    end

    local red, err = redis_cli.new({
        redis_host = redis_conf.host[1], -- Use first host for now
        redis_port = redis_conf.port or 6379,
        redis_password = redis_conf.password,
        redis_database = redis_conf.database or 0,
        redis_timeout = redis_conf.timeout or 1000,
    })

    if not red then
        return nil, nil, err
    end

    return red, redis_conf.prefix or "/apisix"
end

_M.get_redis_cli = get_redis_cli

local function get_revision(red, prefix)
    local rev, err = red:get(prefix .. "/revision")
    if not rev then
        return 0
    end
    if rev == ngx.null then
        return 0
    end
    return tonumber(rev)
end

local function incr_revision(red, prefix)
    return red:incr(prefix .. "/revision")
end

local function notify(red, prefix, key, action)
    local msg = json.encode({key = key, action = action})
    return red:publish(prefix .. "/config_events", msg)
end

function _M.get(key, is_dir)
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local full_key = prefix .. key
    local res = {
        headers = {},
        body = {
            header = {}
        },
        status = 200
    }

    local rev = get_revision(red, prefix)
    res.headers["X-Etcd-Index"] = tostring(rev)
    res.body.header.revision = tostring(rev)

    if not is_dir then
        local val, err = red:get(full_key)
        if not val then
            return nil, err
        end

        if val == ngx.null then
            res.status = 404
            res.body.message = "Key not found"
            return res
        end

        local data = json.decode(val)
        res.body.node = {
            key = full_key,
            value = data.value,
            modifiedIndex = data.revision,
            createdIndex = data.revision, -- For now
        }
    else
        -- readdir using SCAN
        local cursor = "0"
        local all_keys = {}
        repeat
            local res, err = red:scan(cursor, "MATCH", full_key .. "*", "COUNT", 100)
            if not res then
                return nil, err
            end
            cursor = res[1]
            local keys = res[2]
            for _, k in ipairs(keys) do
                table.insert(all_keys, k)
            end
        until cursor == "0"

        res.body.node = {
            dir = true,
            key = full_key,
            nodes = {}
        }

        for _, k in ipairs(all_keys) do
            if k ~= full_key then
                local val, err = red:get(k)
                if val and val ~= ngx.null then
                    local data = json.decode(val)
                    table.insert(res.body.node.nodes, {
                        key = k,
                        value = data.value,
                        modifiedIndex = data.revision,
                        createdIndex = data.revision,
                    })
                end
            end
        end
    end

    -- Close or set keepalive
    red:set_keepalive(10000, 100)

    return res
end

function _M.set(key, value, ttl)
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local full_key = prefix .. key
    local rev, err = incr_revision(red, prefix)
    if not rev then
        return nil, err
    end

    local data = {
        value = value,
        revision = rev
    }

    local ok, err
    if ttl then
        ok, err = red:setex(full_key, ttl, json.encode(data))
    else
        ok, err = red:set(full_key, json.encode(data))
    end

    if not ok then
        return nil, err
    end

    notify(red, prefix, key, "set")

    local res = {
        status = 201,
        headers = { ["X-Etcd-Index"] = tostring(rev) },
        body = {
            header = { revision = tostring(rev) },
            node = {
                key = full_key,
                value = value,
                modifiedIndex = rev
            }
        }
    }

    red:set_keepalive(10000, 100)
    return res
end

function _M.delete(key)
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local full_key = prefix .. key
    local rev, err = incr_revision(red, prefix)
    if not rev then
        return nil, err
    end

    local ok, err = red:del(full_key)
    if not ok then
        return nil, err
    end

    notify(red, prefix, key, "delete")

    local res = {
        status = 200,
        headers = { ["X-Etcd-Index"] = tostring(rev) },
        body = {
            header = { revision = tostring(rev) },
            deleted = "1",
            node = {
                key = full_key
            }
        }
    }

    red:set_keepalive(10000, 100)
    return res
end

function _M.push(key, value, ttl)
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local rev, err = incr_revision(red, prefix)
    if not rev then
        return nil, err
    end

    local index = string.format("%020d", rev)
    value.id = index
    
    local full_key = prefix .. key .. "/" .. index
    local data = {
        value = value,
        revision = rev
    }

    local ok, err
    if ttl then
        ok, err = red:setex(full_key, ttl, json.encode(data))
    else
        ok, err = red:set(full_key, json.encode(data))
    end

    if not ok then
        return nil, err
    end

    notify(red, prefix, key .. "/" .. index, "set")

    local res = {
        status = 201,
        headers = { ["X-Etcd-Index"] = tostring(rev) },
        body = {
            header = { revision = tostring(rev) },
            node = {
                key = full_key,
                value = value,
                modifiedIndex = rev
            }
        }
    }

    red:set_keepalive(10000, 100)
    return res
end

function _M.atomic_set(key, value, ttl, mod_revision)
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local full_key = prefix .. key
    
    -- Lua script for atomic CAS
    local script = [[
        local key = KEYS[1]
        local val = ARGV[1]
        local exp = ARGV[2]
        local prev_rev = ARGV[3]
        local new_rev_key = KEYS[2]

        local old_val = redis.call('GET', key)
        if old_val then
            local old_data = cjson.decode(old_val)
            if tostring(old_data.revision) ~= tostring(prev_rev) then
                return {err = "value changed before overwritten"}
            end
        end

        local new_rev = redis.call('INCR', new_rev_key)
        local new_data = {value = cjson.decode(val), revision = new_rev}
        local new_val_str = cjson.encode(new_data)
        
        if exp ~= "0" then
            redis.call('SETEX', key, exp, new_val_str)
        else
            redis.call('SET', key, new_val_str)
        end
        
        return new_rev
    ]]

    local exp = ttl or 0
    local res, err = red:eval(script, 2, full_key, prefix .. "/revision", json.encode(value), exp, mod_revision)
    
    if not res then
        return nil, err
    end

    if type(res) == "table" and res.err then
        return nil, res.err
    end

    local new_rev = res
    notify(red, prefix, key, "set")

    local resp = {
        status = 200,
        headers = { ["X-Etcd-Index"] = tostring(new_rev) },
        body = {
            succeeded = true,
            header = { revision = tostring(new_rev) },
            node = {
                key = full_key,
                value = value,
            }
        }
    }

    red:set_keepalive(10000, 100)
    return resp
end

function _M.server_version()
    local red, prefix, err = get_redis_cli()
    if not red then
        return nil, err
    end

    local info, err = red:info("server")
    if not info then
        return nil, err
    end

    local version = info:match("redis_version:([^\r\n]+)")
    
    red:set_keepalive(10000, 100)
    return {
        body = {
            redis_version = version
        }
    }
end

-- Dummy keepalive for etcd compatibility if needed
function _M.keepalive(id)
    return true
end

-- Compat for config_redis
function _M.get_redis_syncer()
    return get_redis_cli()
end

-- Compat
function _M.kvs_to_node(kvs)
    return kvs
end

return _M
