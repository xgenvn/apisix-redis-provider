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

local table        = require("apisix.core.table")
local config_local = require("apisix.core.config_local")
local config_util  = require("apisix.core.config_util")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local redis_store  = require("apisix.core.redis_store")
local new_tab      = require("table.new")
local inspect      = require("inspect")
local process      = require("ngx.process")
local check_schema = require("apisix.core.schema").check
local exiting      = ngx.worker.exiting
local worker_id    = ngx.worker.id
local insert_tab   = table.insert
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable
local ngx_sleep    = require("apisix.core.utils").sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local ngx          = ngx
local sub_str      = string.sub
local tostring     = tostring
local tonumber     = tonumber
local xpcall       = xpcall
local debug        = debug
local string       = string
local error        = error
local pairs        = pairs
local next         = next
local assert       = assert
local rand         = math.random
local semaphore    = require("ngx.semaphore")
local tablex       = require("pl.tablex")
local ngx_thread_spawn = ngx.thread.spawn

local _M = {
    version = 0.1,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}

local mt = {
    __index = _M,
    __tostring = function(self)
        return " redis key: " .. self.key
    end
}

local created_obj = {}
local watch_ctx

local function init_watch_ctx()
    if watch_ctx then
        return
    end

    watch_ctx = {
        res = {},
        sema = {},
        started = false,
    }
end

local function run_redis_watch(premature)
    if premature then
        return
    end

    local red, prefix, err = redis_store.get_redis_cli()
    if not red then
        log.error("failed to get redis cli for watch: ", err)
        ngx_sleep(3)
        return ngx_timer_at(0, run_redis_watch)
    end

    local ok, err = red:subscribe(prefix .. "/config_events")
    if not ok then
        log.error("failed to subscribe to redis events: ", err)
        ngx_sleep(3)
        return ngx_timer_at(0, run_redis_watch)
    end

    log.info("subscribed to redis events on channel: ", prefix .. "/config_events")
    watch_ctx.started = true

    while not exiting() do
        local res, err = red:read_reply()
        if not res then
            if err ~= "timeout" then
                log.error("redis subscribe read error: ", err)
                break
            end
        else
            -- [ "message", channel, data ]
            if res[1] == "message" then
                local data = json.decode(res[3])
                if data then
                    -- Notify watchers
                    for _, sema in pairs(watch_ctx.sema) do
                        sema:post()
                    end
                end
            end
        end
    end

    watch_ctx.started = false
    red:set_keepalive(10000, 100)

    if not exiting() then
        ngx_timer_at(0, run_redis_watch)
    end
end

local function short_key(self, str)
    return sub_str(str, #self.key + 2)
end

local function load_full_data(self, dir_res, headers)
    local err
    local changed = false

    if self.single_item then
        self.values = new_tab(1, 0)
        self.values_hash = new_tab(0, 1)

        local item = dir_res
        local data_valid = item.value ~= nil

        if data_valid and self.item_schema then
            data_valid, err = check_schema(self.item_schema, item.value)
            if not data_valid then
                log.error("failed to check item data of [", self.key,
                          "] err:", err, " ,val: ", json.encode(item.value))
            end
        end

        if data_valid and self.checker then
            data_valid, err = self.checker(item.value)
            if not data_valid then
                log.error("failed to check item data of [", self.key,
                          "] err:", err, " ,val: ", json.delay_encode(item.value))
            end
        end

        if data_valid then
            changed = true
            insert_tab(self.values, item)
            self.values_hash[self.key] = #self.values
            item.clean_handlers = {}
            if self.filter then self.filter(item) end
        end

    else
        local values = (dir_res and dir_res.nodes) or dir_res
        if not values then values = {} end

        self.values = new_tab(#values, 0)
        self.values_hash = new_tab(0, #values)

        for _, item in ipairs(values) do
            local key = short_key(self, item.key)
            local data_valid = true
            if type(item.value) ~= "table" then
                data_valid = false
                log.error("invalid item data of [", self.key .. "/" .. key,
                          "], val: ", item.value,
                          ", it should be an object")
            end

            if data_valid and self.item_schema then
                data_valid, err = check_schema(self.item_schema, item.value)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.encode(item.value))
                end
            end

            if data_valid and self.checker then
                data_valid, err = self.checker(item.value, item.key)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item.value))
                end
            end

            if data_valid then
                changed = true
                insert_tab(self.values, item)
                self.values_hash[key] = #self.values
                item.value.id = key
                item.clean_handlers = {}
                if self.filter then self.filter(item) end
            end
        end
    end

    if headers then
        self.prev_index = tonumber(headers["X-Etcd-Index"]) or 0
    end

    if changed then
        self.conf_version = self.conf_version + 1
    end

    self.need_reload = false
end

local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    local res, err = redis_store.get(sub_str(self.key, #self.prefix + 1), not self.single_item)
    if not res then
        return false, err
    end

    if self.values then
        for i, val in ipairs(self.values) do
            config_util.fire_all_clean_handlers(val)
        end
        self.values = nil
        self.values_hash = nil
    end

    local dir_res, headers = res.body.node or {}, res.headers
    load_full_data(self, dir_res, headers)

    return true
end

local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    init_watch_ctx()
    if not watch_ctx.started then
        ngx_timer_at(0, run_redis_watch)
    end

    local sema, err = semaphore.new()
    if not sema then
        error(err)
    end
    watch_ctx.sema[self.key] = sema

    while not exiting() and self.running do
        local ok, err = xpcall(function()
            local ok, err = sync_data(self)
            if not ok then
                log.error("failed to fetch data from redis: ", err)
                ngx_sleep(self.resync_delay)
            else
                -- Wait for next event
                sema:wait(60)
            end
        end, debug.traceback)

        if not ok then
            log.error("xpcall error in redis fetch: ", err)
            ngx_sleep(self.resync_delay)
        end
    end
end

function _M.new(key, opts)
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end

    local redis_conf = local_conf.deployment.redis
    local prefix = redis_conf.prefix or "/apisix"
    local resync_delay = redis_conf.resync_delay or 5

    local automatic = opts and opts.automatic
    local item_schema = opts and opts.item_schema
    local filter_fun = opts and opts.filter
    local timeout = opts and opts.timeout
    local single_item = opts and opts.single_item
    local checker = opts and opts.checker

    local obj = setmetatable({
        key = key and prefix .. key,
        prefix = prefix,
        automatic = automatic,
        item_schema = item_schema,
        checker = checker,
        sync_times = 0,
        running = true,
        conf_version = 0,
        values = {},
        need_reload = true,
        prev_index = 0,
        resync_delay = resync_delay,
        timeout = timeout,
        single_item = single_item,
        filter = filter_fun,
    }, mt)

    if automatic then
        ngx_timer_at(0, _automatic_fetch, obj)
    else
        -- Initial sync
        sync_data(obj)
    end

    if key then
        created_obj[key] = obj
    end

    return obj
end

function _M.fetch_created_obj(key)
    return created_obj[key]
end

function _M.get(self, key)
    if not self.values_hash then
        return
    end

    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end

function _M.init()
    return true
end

function _M.init_worker()
    return true
end

return _M
