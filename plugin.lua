local events      = require("porla_events")
local http_client = require("porla_http_client")
local log         = require("porla_log")
local timers      = require("porla_timers")

-- line protocol needs commas, equals signs and spaces in tag values escaped
local function tag(value)
    return (value:gsub("[,= ]", "\\%0"))
end

return {
    init = function(config)
        assert(config and config.url and config.bucket, "influxdb needs url and bucket in its config")

        local url     = config.url .. "/api/v2/write?precision=ns&bucket=" .. config.bucket
        local headers = { ["Content-Type"] = "text/plain; charset=utf-8" }

        if config.token then
            headers["Authorization"] = "Token " .. config.token
        end

        -- every session writes every tick, so log only when writes start failing and when they work again;
        -- a request that times out can finish after newer ones went through, so only newer outcomes count
        local sent, newest, failing = 0, 0, false

        local function report(seq, problem)
            if seq < newest then
                return
            end

            newest = seq

            if problem ~= nil and not failing then
                log.warning("InfluxDB writes are failing: " .. problem)
            elseif problem == nil and failing then
                log.info("InfluxDB writes work again")
            end

            failing = problem ~= nil
        end

        events.on("session.stats", function(e)
            if e.session == nil then
                return
            end

            local tables = {}

            for name, value in pairs(e.stats) do
                local measurement, field = name:match("^(.-)%.(.+)$")
                tables[measurement] = tables[measurement] or {}
                table.insert(tables[measurement], field .. "=" .. value .. "i")
            end

            local session = tag(e.session.name)
            local ts      = timers.epoch() * 1000000
            local lines   = {}

            for measurement, fields in pairs(tables) do
                table.insert(lines, ("%s,session=%s %s %d"):format(measurement, session, table.concat(fields, ","), ts))
            end

            local request = { method = "POST", headers = headers, body = table.concat(lines, "\n"), timeout = 5 }

            sent = sent + 1
            local seq = sent

            http_client.request(url, request, function(err, res)
                if err ~= nil then
                    report(seq, tostring(err))
                elseif res.status >= 300 then
                    report(seq, ("HTTP %d %s"):format(res.status, res.body))
                else
                    report(seq, nil)
                end
            end)
        end)
    end
}

