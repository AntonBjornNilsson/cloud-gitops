// grafana-folder: Home Automation
// Home Assistant: entities, sensors (climate, power, batteries), blinds and
// switches, state-change activity and the pod's health.
// Metrics: Home Assistant's prometheus integration (VMPodScrape homeassistant).
// Every entity carries entity/friendly_name/domain labels; panels for device
// types that are not set up yet show "no data" until one is added.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local ns = '{namespace="homeassistant"}';
local battery = [{ color: 'red', value: null }, { color: 'orange', value: 20 }, { color: 'green', value: 40 }];
// Always-"unknown" entities are reported as unavailable too; count only those
// that were available at some point this week.
local wentDown = 'homeassistant_entity_available == 0 and max_over_time(homeassistant_entity_available[7d]) == 1';
local issues = [{ color: 'green', value: null }, { color: 'orange', value: 1 }];

dashboard.new('Home Assistant')
+ dashboard.withUid('home-assistant')
+ dashboard.withDescription('Home Assistant entities, sensors, blinds and switches, activity and pod health.')
+ dashboard.withTags(['home-automation', 'homeassistant'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('Entities', 'count(homeassistant_entity_available)', 0, 1),
  m.stat('Unavailable', 'count(%s) or vector(0)' % wentDown, 3, 1,
         thresholds=issues, graph=true, desc='Entities that were available this week but are not now: device offline or integration failed to load.'),
  m.stat('Blinds open', 'count(homeassistant_cover_position > 0) or vector(0)', 6, 1,
         desc='Covers (blinds) not fully closed.'),
  m.stat('Switches on', 'count(homeassistant_switch_state == 1) or vector(0)', 9, 1, noValue='-'),
  m.stat('Low batteries', 'count(homeassistant_sensor_battery_percent < 20) or vector(0)', 12, 1,
         thresholds=issues, desc='Battery sensors below 20%.'),
  m.stat('State changes/h', 'sum(rate(homeassistant_state_change_total[1h])) * 3600', 15, 1, graph=true),
  m.stat('Uptime', 'time() - max(process_start_time_seconds%s)' % ns, 18, 1, unit='s',
         thresholds=[{ color: 'orange', value: null }, { color: 'green', value: 3600 }]),
  m.stat('Memory', 'max(process_resident_memory_bytes%s)' % ns, 21, 1, unit='bytes', graph=true),
  m.barGauge('Entities by domain', [q('sort_desc(count by (domain) (homeassistant_entity_available))', '{{domain}}')], 0, 5, 8, 9),
  m.labelTable('Unavailable entities', wentDown, 8, 5, 16, 9,
               rename={ friendly_name: 'Name', entity: 'Entity', domain: 'Domain' },
               exclude={ Value: true },
               desc='Entities that were available this week but are not now. Entities that are always "unknown" (backup sensors, TTS, button events before the first press) are left out.'),

  // --- Climate ------------------------------------------------------------------
  m.row('Climate', 14),
  m.ts('Temperature', [
    q('homeassistant_sensor_temperature_celsius', '{{friendly_name}}'),
  ], 0, 15, 12, 8, 'celsius'),
  m.ts('Humidity', [
    q('homeassistant_sensor_humidity_percent', '{{friendly_name}}'),
  ], 12, 15, 12, 8, 'percent', min=0),
  m.ts('Thermostats (current / target)', [
    q('homeassistant_climate_current_temperature_celsius', '{{friendly_name}} current'),
    q('homeassistant_climate_target_temperature_celsius', '{{friendly_name}} target'),
  ], 0, 23, 24, 7, 'celsius'),

  // --- Energy -------------------------------------------------------------------
  m.row('Energy', 30),
  m.ts('Power', [
    q('homeassistant_sensor_power_w', '{{friendly_name}}'),
  ], 0, 31, 12, 8, 'watt', min=0),
  m.barGauge('Energy used (time range)', [
    q('sort_desc(increase(homeassistant_sensor_energy_kwh[$__range]) > 0)', '{{friendly_name}}'),
  ], 12, 31, 12, 8, 'kwatth',
    desc='Increase of energy meters (kWh) over the selected time range.'),

  // --- Devices ------------------------------------------------------------------
  m.row('Blinds, switches and batteries', 39),
  m.ts('Blind position', [
    q('homeassistant_cover_position', '{{friendly_name}}'),
  ], 0, 40, 12, 8, 'percent', min=0,
    desc='0 = closed, 100 = open. IKEA blinds via the DIRIGERA Matter bridge report here.'),
  m.ts('Switches and binary sensors', [
    q('homeassistant_switch_state', '{{friendly_name}}'),
    q('homeassistant_binary_sensor_state', '{{friendly_name}}'),
  ], 12, 40, 12, 8, 'short', min=0,
    desc='1 = on / open / detected, 0 = off.'),
  m.barGauge('Battery level (lowest first)', [
    q('sort(homeassistant_sensor_battery_percent)', '{{friendly_name}}'),
  ], 0, 48, 12, 10, 'percent', battery, 0, 100),
  m.ts('State changes by domain', [
    q('sum by (domain) (rate(homeassistant_state_change_total[$__rate_interval])) * 3600', '{{domain}}'),
  ], 12, 48, 12, 10, 'short', true, 0,
    desc='State changes per hour, by entity domain. A busy entity can bloat the recorder database.'),
  m.labelTable('Most active entities (time range)',
               'topk(15, sum by (entity, friendly_name, domain) (increase(homeassistant_state_change_total[$__range])) > 0)',
               0, 58, 24, 8,
               rename={ friendly_name: 'Name', entity: 'Entity', domain: 'Domain', Value: 'State changes' },
               sortBy={ displayName: 'State changes', desc: true }),

  // --- Service ------------------------------------------------------------------
  m.row('Pod and traffic', 66),
]
+ m.serviceStrip('Home Assistant', 'homeassistant', 67)
+ [
  m.ts('Process CPU', [
    q('rate(process_cpu_seconds_total%s[$__rate_interval])' % ns, 'cpu'),
  ], 0, 73, 8, 7, 'cores', false, 0, legendRight=false),
  m.ts('Open file descriptors', [
    q('process_open_fds%s' % ns, 'open'),
    q('process_max_fds%s' % ns, 'max'),
  ], 8, 73, 8, 7, 'short', false, 0, legendRight=false),
  m.ts('Config volume', [
    q('kubelet_volume_stats_used_bytes{namespace="homeassistant"}', 'used'),
    q('kubelet_volume_stats_capacity_bytes{namespace="homeassistant"}', 'capacity'),
  ], 16, 73, 8, 7, 'bytes', false, 0, legendRight=false,
    desc='The recorder database (home-assistant_v2.db) lives here.'),
  m.logs('Errors and warnings', m.errorLogs('homeassistant'), 0, 80, 24, 10),
])
