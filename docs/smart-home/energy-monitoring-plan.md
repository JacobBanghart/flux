# Smart Home Energy Monitoring Platform

## Overview

This document outlines energy monitoring solutions for ESPHome smart plugs that provide:
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

## Architecture Options Comparison

### Quick Comparison

| Criteria | TIG Stack ⭐ | Kafka + ksqlDB |
|----------|-------------|----------------|
| **Complexity** | Low-Medium | High |
| **Components** | 2-3 services | 4-5 services |
| **Memory Footprint** | ~300-500MB | ~1.75GB+ |
| **Setup Time** | 1-2 hours | 4-8 hours |
| **Learning Curve** | Gentle (Flux query lang) | Steep (Kafka, ksqlDB, connectors) |
| **Scales to 100+ devices** | Yes, but slower | Yes, easily |
| **Event replay** | No | Yes |
| **Exactly-once semantics** | No | Yes |
| **Best for** | Home use (4-20 devices) | Enterprise / IoT at scale |

---

## Option A: TIG Stack (Telegraf + InfluxDB) ⭐ RECOMMENDED

**Best for: Home use with 4-50 devices**

### Architecture

```
┌──────────────┐    MQTT     ┌───────────┐           ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │──────────▶│  Telegraf   │
│  Smart Plugs │             └───────────┘           └──────┬──────┘
└──────────────┘                   ▲                        │
                                   │                        ▼
┌──────────────┐            ┌──────┴──────┐          ┌─────────────┐
│    Home      │◀───────────│  Telegraf   │◀─────────│  InfluxDB   │
│  Assistant   │  (MQTT)    │  (output)   │ (tasks)  │   2.x       │
└──────────────┘            └─────────────┘          └──────┬──────┘
                                                            │
                                                     ┌──────▼──────┐
                                                     │   Grafana   │
                                                     │ (optional)  │
                                                     └─────────────┘
```

### How It Works

1. **Telegraf** subscribes to MQTT topics, writes raw power readings to InfluxDB
2. **InfluxDB Tasks** (built-in cron jobs) calculate hourly/daily/monthly/yearly rollups
3. **Telegraf** (or InfluxDB alerts) publishes rollup values back to MQTT
4. **Home Assistant** sees rollup sensors via native MQTT discovery (zero HA config)
5. **Grafana** (optional) provides historical dashboards

### Pros

| Pro | Details |
|-----|---------|
| ✅ **Lightweight** | ~300-500MB RAM total vs ~1.75GB for Kafka |
| ✅ **Simple setup** | 2-3 K8s manifests vs 10+ for Kafka |
| ✅ **Battle-tested for metrics** | InfluxDB designed specifically for time-series |
| ✅ **Built-in downsampling** | InfluxDB tasks replace ksqlDB |
| ✅ **Native HA integration** | Both MQTT feedback AND direct InfluxDB sensor |
| ✅ **Great Grafana integration** | First-class data source support |
| ✅ **Lower operational burden** | Fewer moving parts to monitor/upgrade |
| ✅ **Sufficient for home scale** | Handles thousands of metrics/second |

### Cons

| Con | Details |
|-----|---------|
| ❌ **No event replay** | Can't reprocess historical data with new logic |
| ❌ **No exactly-once** | Rare edge case: duplicate writes on network hiccup |
| ❌ **Flux learning curve** | InfluxDB 2.x uses Flux query language |
| ❌ **Less flexible transforms** | Tasks are simpler than ksqlDB streams |
| ❌ **Single point of failure** | No built-in replication (fine for home use) |

### Resource Requirements

| Component | CPU Request | Memory Request | Storage |
|-----------|-------------|----------------|---------|
| Telegraf | 50m | 64Mi | - |
| InfluxDB 2.x | 200m | 256Mi | 10Gi |
| Grafana (optional) | 100m | 128Mi | 1Gi |
| **Total** | **350m** | **448Mi** | **11Gi** |

### Implementation Phases (TIG)

#### Phase 1: InfluxDB
- [ ] Deploy InfluxDB 2.x to `smart-home` namespace
- [ ] Create organization and bucket for energy data
- [ ] Configure retention policy (raw: 30 days, rollups: forever)

#### Phase 2: Telegraf MQTT Input
- [ ] Deploy Telegraf with MQTT consumer input
- [ ] Subscribe to ESPHome power topics
- [ ] Write to InfluxDB with proper tags (device, metric)

#### Phase 3: InfluxDB Tasks (Rollups)
- [ ] Create hourly aggregation task
- [ ] Create daily aggregation task
- [ ] Create monthly aggregation task
- [ ] Create lifetime total task (never resets)

#### Phase 4: MQTT Output (HA Integration)
- [ ] Configure Telegraf MQTT output OR InfluxDB alert
- [ ] Publish rollups with HA MQTT discovery format
- [ ] Verify sensors auto-appear in Home Assistant

#### Phase 5: Grafana Dashboards (Optional)
- [ ] Deploy Grafana
- [ ] Connect to InfluxDB data source
- [ ] Create energy monitoring dashboard

### Telegraf Configuration Example

```toml
# Input: MQTT from ESPHome
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.home-assistant:1883"]
  topics = [
    "homeassistant/sensor/+/power/state",
    "homeassistant/sensor/+/voltage/state",
    "homeassistant/sensor/+/current/state"
  ]
  data_format = "value"
  data_type = "float"
  
  # Extract device name from topic
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "homeassistant/sensor/+/+/state"
    tags = "_/_/device/measurement/_"

# Output: InfluxDB
[[outputs.influxdb_v2]]
  urls = ["http://influxdb.smart-home:8086"]
  token = "${INFLUXDB_TOKEN}"
  organization = "home"
  bucket = "energy"

# Output: MQTT (publish rollups back for HA)
[[outputs.mqtt]]
  servers = ["tcp://mosquitto.home-assistant:1883"]
  topic_prefix = "homeassistant/sensor"
  data_format = "json"
  # Only output processed aggregates, not raw
  [outputs.mqtt.tagpass]
    aggregation = ["hourly", "daily", "monthly", "lifetime"]
```

### InfluxDB Task Example (Daily Rollup)

```flux
option task = {name: "daily_energy_rollup", every: 1h}

from(bucket: "energy")
  |> range(start: today())
  |> filter(fn: (r) => r._measurement == "power")
  |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
  |> map(fn: (r) => ({r with 
    _measurement: "energy_daily",
    _value: r._value * 24.0 / 1000.0  // avg watts * hours / 1000 = kWh
  }))
  |> to(bucket: "energy_rollups", org: "home")
```

---

## Option B: Kafka + ksqlDB (Enterprise Scale)

**Best for: 50+ devices, complex event processing, or enterprise requirements**

### Architecture

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
                                    └─────────────────────────────────────────────┘
```

### Pros

| Pro | Details |
|-----|---------|
| ✅ **Event replay** | Reprocess all historical data with new logic |
| ✅ **Exactly-once semantics** | Guaranteed no duplicates or data loss |
| ✅ **Massive scale** | Handles millions of events/second |
| ✅ **Complex stream processing** | Joins, windows, stateful aggregations |
| ✅ **Decoupled architecture** | Add new consumers without touching producers |
| ✅ **Industry standard** | Well-documented, large community |
| ✅ **Multi-sink capable** | Write to InfluxDB, TimescaleDB, S3, etc. simultaneously |

### Cons

| Con | Details |
|-----|---------|
| ❌ **Heavy resource usage** | ~1.75GB+ RAM minimum |
| ❌ **Complex setup** | Strimzi operator, Connect, ksqlDB, connectors |
| ❌ **Operational overhead** | More components to monitor, upgrade, debug |
| ❌ **Overkill for 4 devices** | Engineering cost not justified at home scale |
| ❌ **Steep learning curve** | Kafka concepts, ksqlDB syntax, connector configs |
| ❌ **Slower iteration** | Schema registry, topic configs, connector debugging |

### Resource Requirements

| Component | CPU Request | Memory Request | Storage |
|-----------|-------------|----------------|---------|
| Kafka (KRaft, 1 node) | 250m | 512Mi | 10Gi |
| Kafka Connect | 250m | 512Mi | - |
| ksqlDB | 250m | 512Mi | - |
| TimescaleDB | 250m | 256Mi | 20Gi |
| **Total** | **1000m** | **1.75Gi** | **30Gi** |

### When to Choose Kafka

Choose Kafka over TIG stack if you need:
- [ ] More than 50 IoT devices
- [ ] Complex event processing (joins, pattern detection)
- [ ] Ability to replay and reprocess historical events
- [ ] Multi-datacenter replication
- [ ] Exactly-once processing guarantees
- [ ] Multiple downstream consumers (not just HA + Grafana)

---

## Home Assistant Integration Methods

Both TIG Stack and Kafka can integrate with Home Assistant using these methods:

### Option 1: MQTT Feedback Loop ⭐ RECOMMENDED

**Works with: TIG Stack, Kafka**

**How it works**: Aggregated stats are published back to MQTT topics that Home Assistant already consumes natively.

```
┌──────────────┐              ┌───────────┐              ┌─────────────┐
│   ESPHome    │────────────▶ │ Mosquitto │────────────▶ │  Telegraf   │
│  (raw data)  │              └───────────┘              │  or Kafka   │
└──────────────┘                   ▲                     └──────┬──────┘
                                   │                            │
┌──────────────┐            ┌──────┴──────┐              ┌──────▼──────┐
│    Home      │◀───────────│   MQTT      │◀─────────────│  InfluxDB   │
│  Assistant   │  (native)  │   Output    │  (rollups)   │  or ksqlDB  │
└──────────────┘            └─────────────┘              └─────────────┘
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

**Works with: TIG Stack (native), Kafka (via sink connector)**

**How it works**: Data stored in InfluxDB, which Home Assistant queries directly.

```
┌──────────────┐    MQTT     ┌───────────┐              ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │────────────▶ │  Telegraf   │
└──────────────┘             └───────────┘              │  or Kafka   │
                                                        └──────┬──────┘
                                                               │
┌──────────────┐            ┌─────────────┐             ┌──────▼──────┐
│    Home      │◀───────────│  InfluxDB   │◀────────────│   Writer    │
│  Assistant   │  (native)  │   2.x       │             └─────────────┘
└──────────────┘            └─────────────┘
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

**Works with: Kafka (via JDBC sink), TIG Stack (via Telegraf PostgreSQL output)**

**How it works**: Data stored in TimescaleDB, HA queries via native SQL sensor.

```
┌──────────────┐    MQTT     ┌───────────┐              ┌─────────────┐
│   ESPHome    │────────────▶│ Mosquitto │────────────▶ │  Telegraf   │
└──────────────┘             └───────────┘              │  or Kafka   │
                                                        └──────┬──────┘
                                                               │
┌──────────────┐            ┌─────────────┐             ┌──────▼──────┐
│    Home      │◀───────────│ TimescaleDB │◀────────────│   Writer    │
│  Assistant   │   (SQL)    │  (Postgres) │             └─────────────┘
└──────────────┘            └─────────────┘
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

## Recommendation

**For 4 smart plugs: Use the TIG Stack (Option A)**

The TIG Stack provides all the functionality you need:
- ✅ Long-term data retention (years)
- ✅ Automatic rollups (hourly, daily, monthly, yearly)
- ✅ Lifetime energy totals that survive device reboots
- ✅ Native Home Assistant integration via MQTT
- ✅ Beautiful Grafana dashboards
- ✅ ~5x less resource usage than Kafka

Kafka is overkill unless you plan to scale to 50+ devices or need advanced stream processing features like event replay.

---

## Kafka Implementation Details (Reference)

*Skip this section if using TIG Stack*

### Implementation Phases (Kafka)
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

### Kafka Resource Requirements

| Component | CPU Request | Memory Request | Storage |
|-----------|-------------|----------------|---------|
| Kafka (KRaft, 1 node) | 250m | 512Mi | 10Gi |
| Kafka Connect | 250m | 512Mi | - |
| ksqlDB | 250m | 512Mi | - |
| TimescaleDB | 250m | 256Mi | 20Gi |
| **Total** | **1000m** | **1.75Gi** | **30Gi** |

*Note: This is a minimal single-node setup suitable for home use.*

---

## Data Flow Example (Both Architectures)

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

*Note: TIG Stack publishes the same format via Telegraf MQTT output*

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

## ksqlDB Query Examples (Kafka Only)

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

### TIG Stack (Recommended)

```
clusters/k3s-cluster/smart-home/
├── namespace.yaml
├── kustomization.yaml
├── influxdb/
│   ├── kustomization.yaml
│   ├── influxdb.yaml
│   └── influxdb-tasks.yaml        # Rollup task definitions
├── telegraf/
│   ├── kustomization.yaml
│   ├── telegraf.yaml
│   └── telegraf-config.yaml       # MQTT input + InfluxDB output
└── grafana/                       # Optional
    ├── kustomization.yaml
    ├── grafana.yaml
    └── dashboards/
        └── energy-monitoring.json
```

### Kafka Stack (Enterprise)

```
clusters/k3s-cluster/smart-home/
├── namespace.yaml
├── kustomization.yaml
├── kafka/
│   ├── kustomization.yaml
│   ├── strimzi-operator.yaml
│   ├── kafka-cluster.yaml
│   └── kafka-topics.yaml
├── kafka-connect/
│   ├── kustomization.yaml
│   ├── kafka-connect.yaml
│   ├── mqtt-source-connector.yaml
│   └── mqtt-sink-connector.yaml
├── ksqldb/
│   ├── kustomization.yaml
│   ├── ksqldb-server.yaml
│   └── ksqldb-queries.sql
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

1. ✅ Review this plan and confirm architecture choice (TIG recommended)
2. Begin Phase 1: Deploy InfluxDB
3. Configure Telegraf MQTT → InfluxDB pipeline
4. Create InfluxDB tasks for rollups
5. Test with single smart plug before expanding
6. (Optional) Add Grafana for dashboards

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-17 | TIG Stack over Kafka | 4 devices doesn't justify Kafka complexity; ~5x less resources |
| 2026-01-17 | MQTT feedback for HA | Zero HA config changes, auto-discovery |
