# Smart Home Energy Monitoring Platform

## Overview

This document outlines a Kafka-based energy monitoring solution for ESPHome smart plugs that provides:
- Long-term event data retention (years of history)
- Automatic rollups (hourly, daily, monthly, yearly)
- Integration with Home Assistant **without custom connectors**
- No data loss on device flash/reboot

## Current State

```
┌──────────────────┐     MQTT      ┌───────────────┐     ┌─────────────────┐
│   ESPHome S31    │──────────────▶│   Mosquitto   │────▶│  Home Assistant │
│   Smart Plugs    │   (5s data)   │   (NodePort)  │     │    (native)     │
└──────────────────┘               └───────────────┘     └─────────────────┘
```

### Problems with Current Setup

| Issue | Impact |
|-------|--------|
| Energy totals stored on device | Lost on flash/reboot/power loss |
| No historical aggregation | Can't query "energy used in March 2024" |
| HA recorder database | Not designed for time-series at scale |
| Daily energy resets at midnight | Lost if device offline at reset time |

---

## Home Assistant Integration Options (No Custom Connectors)

### Option 1: MQTT Feedback Loop ⭐ RECOMMENDED

**How it works**: Aggregated stats are published back to MQTT topics that Home Assistant already consumes natively.

```
┌──────────────┐    MQTT     ┌───────────┐    Kafka    ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │────────────▶│   Kafka     │
│  (raw data)  │             └───────────┘             │  Connect    │
└──────────────┘                   ▲                   └──────┬──────┘
                                   │                          │
┌──────────────┐            ┌──────┴──────┐            ┌──────▼──────┐
│    Home      │◀───────────│   MQTT      │◀───────────│   ksqlDB    │
│  Assistant   │  (native)  │   Sink      │ (rollups)  │ (streaming) │
└──────────────┘            └─────────────┘            └─────────────┘
```

**Pros**:
- Zero changes to Home Assistant
- Uses existing MQTT discovery
- Rollups appear as new sensors automatically
- Simplest HA integration

**Cons**:
- Two-way MQTT flow (slightly more complex)

**Example MQTT topics published back**:
```
homeassistant/sensor/smart-plug-1/energy_hourly/state
homeassistant/sensor/smart-plug-1/energy_daily/state
homeassistant/sensor/smart-plug-1/energy_monthly/state
homeassistant/sensor/smart-plug-1/energy_yearly/state
homeassistant/sensor/smart-plug-1/energy_lifetime/state  # Kafka-managed, never resets
```

---

### Option 2: InfluxDB with Native HA Integration

**How it works**: Kafka sinks data to InfluxDB, which Home Assistant queries natively.

```
┌──────────────┐    MQTT     ┌───────────┐    Kafka    ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │────────────▶│   Kafka     │
└──────────────┘             └───────────┘             └──────┬──────┘
                                                              │
┌──────────────┐            ┌─────────────┐            ┌──────▼──────┐
│    Home      │◀───────────│  InfluxDB   │◀───────────│   Kafka     │
│  Assistant   │  (native)  │   2.x       │  (sink)    │  Connect    │
└──────────────┘            └─────────────┘            └─────────────┘
```

**Pros**:
- InfluxDB is purpose-built for time-series
- Native HA integration via `influxdb` sensor platform
- Built-in downsampling with tasks
- Grafana integration for dashboards

**Cons**:
- InfluxDB 2.x can be resource-heavy
- Requires InfluxDB sensor config in HA
- Flux query language learning curve

**Home Assistant configuration.yaml**:
```yaml
sensor:
  - platform: influxdb
    api_version: 2
    host: influxdb.smart-home.svc.cluster.local
    port: 8086
    token: !secret influxdb_token
    organization: home
    bucket: energy
    queries:
      - name: "Smart Plug 1 Monthly Energy"
        query: >
          from(bucket: "energy")
            |> range(start: -30d)
            |> filter(fn: (r) => r._measurement == "power" and r.device == "smart-plug-1")
            |> aggregateWindow(every: 30d, fn: sum)
```

---

### Option 3: PostgreSQL/TimescaleDB with SQL Sensor

**How it works**: Kafka sinks to TimescaleDB, HA queries via native SQL sensor.

```
┌──────────────┐    MQTT     ┌───────────┐    Kafka    ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │────────────▶│   Kafka     │
└──────────────┘             └───────────┘             └──────┬──────┘
                                                              │
┌──────────────┐            ┌─────────────┐            ┌──────▼──────┐
│    Home      │◀───────────│ TimescaleDB │◀───────────│    JDBC     │
│  Assistant   │   (SQL)    │  (Postgres) │  (sink)    │    Sink     │
└──────────────┘            └─────────────┘            └─────────────┘
```

**Pros**:
- TimescaleDB has automatic data retention policies
- Continuous aggregates for rollups (computed once, stored)
- Standard SQL - no new query language
- HA SQL sensor is simple to configure

**Cons**:
- SQL sensor requires manual entity creation
- No auto-discovery like MQTT

**Home Assistant configuration.yaml**:
```yaml
sensor:
  - platform: sql
    db_url: postgresql://ha_readonly:password@timescaledb.smart-home.svc.cluster.local/energy
    queries:
      - name: "Smart Plug 1 Today Energy"
        query: "SELECT energy_kwh FROM daily_energy WHERE device = 'smart-plug-1' AND date = CURRENT_DATE"
        column: energy_kwh
        unit_of_measurement: kWh
```

---

### Option 4: Prometheus + Home Assistant

**How it works**: Expose metrics via Prometheus, HA scrapes them.

**Pros**: Works well if you already have Prometheus
**Cons**: Prometheus isn't ideal for high-cardinality time-series, HA integration is basic

**Not recommended for this use case.**

---

## Recommended Architecture: MQTT Feedback Loop

Given your existing setup, **Option 1 (MQTT Feedback Loop)** is the best choice because:

1. ✅ Home Assistant already connected to Mosquitto
2. ✅ MQTT discovery auto-creates entities
3. ✅ No HA configuration changes needed
4. ✅ Aggregated sensors appear alongside raw sensors
5. ✅ Kafka handles all computation externally

### Complete Architecture

```
                                    ┌─────────────────────────────────────────────┐
                                    │              Kubernetes (k3s)               │
┌──────────────┐                    │                                             │
│   ESPHome    │    MQTT (raw)      │  ┌───────────┐      ┌──────────────────┐   │
│  Smart Plug  │───────────────────▶│  │ Mosquitto │─────▶│   Kafka Connect  │   │
│    (x4)      │                    │  │  :31883   │      │   (MQTT Source)  │   │
└──────────────┘                    │  └─────┬─────┘      └────────┬─────────┘   │
                                    │        │                     │             │
                                    │        │                     ▼             │
┌──────────────┐    MQTT (rollups)  │        │            ┌──────────────────┐   │
│    Home      │◀───────────────────│        │            │      Kafka       │   │
│  Assistant   │                    │        │            │  (Strimzi/KRaft) │   │
└──────────────┘                    │        │            └────────┬─────────┘   │
                                    │        │                     │             │
                                    │        │                     ▼             │
                                    │        │            ┌──────────────────┐   │
                                    │        │◀───────────│      ksqlDB      │   │
                                    │        │  (sink)    │  (aggregations)  │   │
                                    │                     └────────┬─────────┘   │
                                    │                              │             │
                                    │                              ▼             │
                                    │                     ┌──────────────────┐   │
                                    │                     │   TimescaleDB    │   │
                                    │                     │  (long-term)     │   │
                                    │                     └──────────────────┘   │
                                    │                              │             │
                                    │                              ▼             │
                                    │                     ┌──────────────────┐   │
                                    │                     │     Grafana      │   │
                                    │                     │   (dashboards)   │   │
                                    │                     └──────────────────┘   │
                                    └─────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Kafka Foundation
- [ ] Deploy Strimzi Kafka operator
- [ ] Create Kafka cluster (KRaft mode, no ZooKeeper)
- [ ] Create topics for raw energy data
- [ ] Resource estimate: 512Mi-1Gi RAM for small cluster

### Phase 2: MQTT to Kafka Bridge
- [ ] Deploy Kafka Connect with MQTT Source Connector
- [ ] Configure connector to subscribe to ESPHome topics
- [ ] Verify messages flowing to Kafka topics
- [ ] Topic naming: `esphome.power.raw`

### Phase 3: Stream Processing (ksqlDB)
- [ ] Deploy ksqlDB server
- [ ] Create streams for raw power data
- [ ] Create materialized tables for rollups:
  - Hourly aggregates
  - Daily aggregates
  - Monthly aggregates
  - Yearly aggregates
  - Lifetime totals (never reset)

### Phase 4: MQTT Sink (HA Integration)
- [ ] Configure Kafka Connect MQTT Sink
- [ ] Publish rollups back to Mosquitto
- [ ] Configure MQTT discovery payloads
- [ ] Verify sensors appear in Home Assistant

### Phase 5: Long-term Storage (Optional)
- [ ] Deploy TimescaleDB
- [ ] Configure JDBC Sink Connector
- [ ] Create continuous aggregates
- [ ] Set up retention policies (raw: 30 days, hourly: 1 year, daily: forever)

### Phase 6: Dashboards (Optional)
- [ ] Deploy Grafana
- [ ] Connect to TimescaleDB
- [ ] Create energy monitoring dashboards
- [ ] Historical analysis queries

---

## Resource Requirements

| Component | CPU Request | Memory Request | Storage |
|-----------|-------------|----------------|---------|
| Kafka (KRaft, 1 node) | 250m | 512Mi | 10Gi |
| Kafka Connect | 250m | 512Mi | - |
| ksqlDB | 250m | 512Mi | - |
| TimescaleDB | 250m | 256Mi | 20Gi |
| **Total** | **1000m** | **1.75Gi** | **30Gi** |

*Note: This is a minimal single-node setup suitable for home use.*

---

## Data Flow Example

### Raw ESPHome Message (every 5s)
```json
{
  "topic": "homeassistant/sensor/smart-plug-1/power/state",
  "payload": "145.2"
}
```

### Kafka Raw Event
```json
{
  "device": "smart-plug-1",
  "metric": "power",
  "value": 145.2,
  "unit": "W",
  "timestamp": "2026-01-17T10:30:05Z"
}
```

### ksqlDB Aggregation (published back to MQTT)
```json
{
  "topic": "homeassistant/sensor/smart-plug-1_energy_today/state",
  "payload": "3.45"
}
```

### MQTT Discovery Config (auto-published)
```json
{
  "topic": "homeassistant/sensor/smart-plug-1_energy_today/config",
  "payload": {
    "name": "Jacobs Desktop Energy Today",
    "state_topic": "homeassistant/sensor/smart-plug-1_energy_today/state",
    "unit_of_measurement": "kWh",
    "device_class": "energy",
    "state_class": "total_increasing",
    "unique_id": "smart-plug-1_energy_today_kafka",
    "device": {
      "identifiers": ["smart-plug-1"],
      "name": "Jacobs Desktop Smart Plug"
    }
  }
}
```

---

## ksqlDB Query Examples

### Create Stream from Raw Data
```sql
CREATE STREAM power_readings (
  device VARCHAR,
  power DOUBLE,
  timestamp TIMESTAMP
) WITH (
  KAFKA_TOPIC = 'esphome.power.raw',
  VALUE_FORMAT = 'JSON'
);
```

### Hourly Energy Aggregation
```sql
CREATE TABLE energy_hourly AS
SELECT
  device,
  WINDOWSTART AS window_start,
  SUM(power * 5 / 3600000) AS energy_kwh  -- 5s samples to kWh
FROM power_readings
WINDOW TUMBLING (SIZE 1 HOUR)
GROUP BY device
EMIT CHANGES;
```

### Daily Energy Aggregation
```sql
CREATE TABLE energy_daily AS
SELECT
  device,
  WINDOWSTART AS window_start,
  SUM(power * 5 / 3600000) AS energy_kwh
FROM power_readings
WINDOW TUMBLING (SIZE 1 DAY)
GROUP BY device
EMIT CHANGES;
```

### Lifetime Total (Never Resets)
```sql
CREATE TABLE energy_lifetime AS
SELECT
  device,
  SUM(power * 5 / 3600000) AS energy_kwh
FROM power_readings
GROUP BY device
EMIT CHANGES;
```

---

## ESPHome Configuration Changes

Minimal changes recommended:

1. **Keep raw sensor publishing** (already configured correctly)
2. **Remove `total_daily_energy`** - Kafka will calculate this
3. **Keep `total_energy`** as backup reference only
4. **Increase throttle** on non-critical sensors to reduce load

The device becomes a "dumb sensor" that just reports instantaneous power readings. All aggregation happens in Kafka.

---

## Files to Create

```
smart-home/
├── energy-monitoring-plan.md          # This document
├── namespace.yaml                      # smart-home namespace
├── kafka/
│   ├── kustomization.yaml
│   ├── strimzi-operator.yaml          # Strimzi operator subscription
│   ├── kafka-cluster.yaml             # KRaft cluster definition
│   └── kafka-topics.yaml              # Topic definitions
├── kafka-connect/
│   ├── kustomization.yaml
│   ├── kafka-connect.yaml             # Connect cluster
│   ├── mqtt-source-connector.yaml     # MQTT → Kafka
│   └── mqtt-sink-connector.yaml       # Kafka → MQTT (rollups)
├── ksqldb/
│   ├── kustomization.yaml
│   ├── ksqldb-server.yaml
│   └── ksqldb-queries.sql             # Aggregation queries
├── timescaledb/
│   ├── kustomization.yaml
│   ├── timescaledb.yaml
│   └── init-schema.sql
└── grafana/
    ├── kustomization.yaml
    ├── grafana.yaml
    └── dashboards/
        └── energy-monitoring.json
```

---

## Next Steps

1. Review this plan and confirm architecture choice
2. Decide on optional components (TimescaleDB, Grafana)
3. Begin Phase 1: Kafka Foundation deployment
4. Test with single smart plug before expanding

---

## Alternative: Simpler Stack (No Kafka)

If Kafka feels like overkill, consider:

**Telegraf + InfluxDB + Grafana (TIG Stack)**

```
ESPHome → MQTT → Telegraf → InfluxDB → Home Assistant
                              ↓
                           Grafana
```

- Telegraf subscribes to MQTT, writes to InfluxDB
- InfluxDB tasks handle rollups
- Home Assistant uses native InfluxDB integration
- Much simpler, fewer components
- Trade-off: Less flexible, no event replay

**Recommendation**: Start with TIG stack if you want quick results. Migrate to Kafka later if you need more sophisticated processing.
