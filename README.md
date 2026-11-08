# InfluxDB for Porla

Sends the libtorrent session stats from every Porla session to InfluxDB, each time a session
reports them. Where the [metrics plugin](https://github.com/porla-plugins/metrics) waits for
Prometheus to scrape the latest values, this one keeps every tick, so a 1 second stats interval
gives 1 second resolution.

_The plugin needs Porla 0.51.0 or later._

## Configuration

```lua
return {
    -- where InfluxDB listens (required)
    url = "http://localhost:8181",

    -- the bucket to write to (required); the database name for InfluxDB 3,
    -- "database/retention-policy" for InfluxDB 1.8
    bucket = "porla",

    -- the API token (default: none); "username:password" for InfluxDB 1.8
    token = "apiv3_..."
}
```

The plugin writes line protocol to `/api/v2/write`, so it works with InfluxDB 3, InfluxDB 2,
InfluxDB Cloud, InfluxDB 1.8 and anything else that accepts InfluxDB v2 writes, such as Telegraf's
`influxdb_v2_listener`.

Each write gives up after 5 seconds and its data is dropped. When writes start failing, Porla logs
one warning with the reason, and one line when they work again.

## Data

Every libtorrent stat `<measurement>.<field>` becomes an integer field in that measurement:
`net.sent_payload_bytes` is the field `sent_payload_bytes` in `net`, and
`peer.num_peers_down_requests` is `num_peers_down_requests` in `peer`. Every point has a `session`
tag with the session name, and the time Porla received the stats.

Stats are sent every `timer_session_stats` milliseconds, 5000 by default. Each tick is about 320
fields per session.

Counters (bytes sent, pieces passed and so on) only grow and start over when Porla restarts.
Gauges (peers connected, queued disk jobs and so on) are the current value.

## InfluxDB 3

Create the database with a retention period before Porla's first write, which would otherwise create
it without one:

```sh
influxdb3 create database --retention-period 7d porla
```

`docker-compose.yml` in this repository runs InfluxDB 3 Core and Grafana, with the data source set up
for the `porla` database. Start it with `docker compose up -d`, create the database with
`docker compose exec influxdb influxdb3 create database --retention-period 7d porla`, and set `url`
to `http://localhost:8181`.

## Grafana

With the InfluxDB data source in SQL mode, a gauge per session:

```sql
SELECT time, session, num_peers_down_requests
FROM peer
WHERE $__timeFilter(time)
ORDER BY time
```

A counter as a rate per second, leaving out the drop when Porla restarts:

```sql
SELECT time, session, bytes_per_second FROM (
  SELECT time, session,
    (sent_payload_bytes - LAG(sent_payload_bytes) OVER (PARTITION BY session ORDER BY time))
      / (date_part('epoch', time) - LAG(date_part('epoch', time)) OVER (PARTITION BY session ORDER BY time))
      AS bytes_per_second
  FROM net
  WHERE $__timeFilter(time)
)
WHERE bytes_per_second >= 0
ORDER BY time
```

