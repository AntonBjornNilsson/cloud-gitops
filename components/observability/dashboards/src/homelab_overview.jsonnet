// Grafana home dashboard: one page answering "is anything wrong, and where?"
// Drill-down dashboards live in the Kubernetes / Networking / Platform /
// Storage / Logs folders.
//
// NOTE: this file is rendered into a Flux-substituted manifest, so never use
// the ${var} form for Grafana variables here; use $var.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;
local stat = grafonnet.panel.stat;
local table = grafonnet.panel.table;
local timeSeries = grafonnet.panel.timeSeries;
local stateTimeline = grafonnet.panel.stateTimeline;
local logs = grafonnet.panel.logs;
local prometheus = grafonnet.query.prometheus;

local vm = 'VictoriaMetrics';
local vlogs = { type: 'victoriametrics-logs-datasource', uid: 'VictoriaLogs' };

local q(expr, legend='') =
  prometheus.new(vm, expr)
  + prometheus.withLegendFormat(legend);

local instant(expr) =
  prometheus.new(vm, expr)
  + prometheus.withInstant(true)
  + prometheus.withFormat('table');

local pos(x, y, w, h) = { gridPos: { x: x, y: y, w: w, h: h } };

local thresholds(steps) =
  stat.standardOptions.color.withMode('thresholds')
  + stat.standardOptions.thresholds.withSteps(steps);

local statPanel(title, expr, x, y, steps, unit='short') =
  stat.new(title)
  + stat.queryOptions.withTargets([q(expr)])
  + stat.options.withColorMode('background')
  + stat.options.withGraphMode('none')
  + stat.standardOptions.withUnit(unit)
  + thresholds(steps)
  + pos(x, y, 4, 4);

local ts(title, targets, x, y, w, h, unit='short') =
  timeSeries.new(title)
  + timeSeries.queryOptions.withTargets(targets)
  + timeSeries.standardOptions.withUnit(unit)
  + timeSeries.options.legend.withDisplayMode('table')
  + timeSeries.options.legend.withPlacement('right')
  + timeSeries.options.legend.withCalcs(['lastNotNull', 'max'])
  + timeSeries.options.tooltip.withMode('multi')
  + timeSeries.options.tooltip.withSort('descending')
  + pos(x, y, w, h);

local upDownMappings = [
  { type: 'value', options: { '0': { text: 'DOWN', color: 'red', index: 0 }, '1': { text: 'UP', color: 'green', index: 1 } } },
];

local logsTarget(expr, queryType) = {
  datasource: vlogs,
  editorMode: 'code',
  expr: expr,
  queryType: queryType,
  refId: 'A',
};

dashboard.new('Homelab Overview')
+ dashboard.withUid('homelab-overview')
+ dashboard.withDescription('Central overview: alerts, endpoint availability and latency, traffic, network, internet, resources, storage and logs.')
+ dashboard.withTags(['homelab', 'overview'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-6h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.withPanels([
  // --- Status ---------------------------------------------------------------
  row.new('Status') + pos(0, 0, 24, 1),
  statPanel('Critical alerts', 'count(ALERTS{alertstate="firing", severity="critical"}) or vector(0)', 0, 1,
            [{ color: 'green', value: null }, { color: 'red', value: 1 }]),
  statPanel('Warnings', 'count(ALERTS{alertstate="firing", severity="warning"}) or vector(0)', 4, 1,
            [{ color: 'green', value: null }, { color: 'orange', value: 1 }]),
  statPanel('Endpoints up', 'sum(probe_success{probe_group="ingress"}) / count(probe_success{probe_group="ingress"})', 8, 1,
            [{ color: 'red', value: null }, { color: 'orange', value: 0.9 }, { color: 'green', value: 1 }], 'percentunit'),
  statPanel('Nodes not ready', 'count(kube_node_status_condition{condition="Ready", status="true"} == 0) or vector(0)', 12, 1,
            [{ color: 'green', value: null }, { color: 'red', value: 1 }]),
  statPanel('Flux not ready', 'count(gotk_resource_info{ready="False"}) or vector(0)', 16, 1,
            [{ color: 'green', value: null }, { color: 'orange', value: 1 }]),
  statPanel('Internet', 'max(probe_success{probe_group="internet"})', 20, 1,
            [{ color: 'red', value: null }, { color: 'green', value: 1 }])
  + stat.standardOptions.withMappings(upDownMappings),

  table.new('Firing alerts')
  + table.queryOptions.withTargets([
    instant('sort_desc(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"})'),
  ])
  + table.queryOptions.withTransformations([
    {
      id: 'organize',
      options: {
        excludeByName: { Time: true, Value: true, __name__: true, alertstate: true, alertgroup: true, prometheus: true, endpoint: true, service: true, container: true, job: true, cluster: true, instance: true },
        indexByName: { alertname: 0, severity: 1, namespace: 2 },
      },
    },
  ])
  + table.options.withSortBy([{ displayName: 'severity', desc: false }])
  + pos(0, 5, 24, 8),

  // --- Endpoints ------------------------------------------------------------
  row.new('Endpoints (blackbox probes through Traefik)') + pos(0, 13, 24, 1),
  stateTimeline.new('Availability')
  + stateTimeline.queryOptions.withTargets([q('probe_success{probe_group=~"ingress|internal"}', '{{namespace}} {{ingress}} {{instance}}')])
  + stateTimeline.standardOptions.withMappings(upDownMappings)
  + stateTimeline.options.withShowValue('never')
  + stateTimeline.options.withRowHeight(0.8)
  + pos(0, 14, 12, 12),
  ts('Response time (end to end)', [q('probe_duration_seconds{probe_group="ingress"}', '{{namespace}}/{{ingress}}')], 12, 14, 12, 12, 's'),

  // --- Traffic ----------------------------------------------------------------
  row.new('Traffic') + pos(0, 26, 24, 1),
  ts('Requests/s by service (Traefik)', [q('sum by (exported_service) (rate(traefik_service_requests_total[$__rate_interval]))', '{{exported_service}}')], 0, 27, 12, 9, 'reqps'),
  ts('p95 latency by service (Traefik)', [q('histogram_quantile(0.95, sum by (exported_service, le) (rate(traefik_service_request_duration_seconds_bucket[$__rate_interval])))', '{{exported_service}}')], 12, 27, 12, 9, 's'),
  ts('5xx/s by service (Traefik)', [q('sum by (exported_service, code) (rate(traefik_service_requests_total{code=~"5.."}[$__rate_interval])) > 0', '{{exported_service}} {{code}}')], 0, 36, 12, 9, 'reqps'),
  ts('In-cluster HTTP p95 by workload (Hubble)', [q('histogram_quantile(0.95, sum by (destination_namespace, destination_workload, le) (rate(hubble_http_request_duration_seconds_bucket[$__rate_interval])))', '{{destination_namespace}}/{{destination_workload}}')], 12, 36, 12, 9, 's'),

  // --- Network ----------------------------------------------------------------
  row.new('Network') + pos(0, 45, 24, 1),
  ts('Policy-denied packets/s (Cilium)', [q('sum by (source_namespace, source_workload, destination_namespace, destination_workload) (rate(hubble_drop_total{reason="POLICY_DENIED"}[$__rate_interval])) > 0', '{{source_namespace}}/{{source_workload}} -> {{destination_namespace}}/{{destination_workload}}')], 0, 46, 12, 9, 'pps'),
  ts('Drops/s by reason (Cilium)', [q('sum by (reason) (rate(hubble_drop_total[$__rate_interval])) > 0', '{{reason}}')], 12, 46, 12, 9, 'pps'),
  ts('DNS lookup time', [
    q('probe_dns_lookup_time_seconds{probe_group="dns"}', 'probe {{instance}}'),
    q('histogram_quantile(0.95, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[$__rate_interval])))', 'CoreDNS p95'),
  ], 0, 55, 12, 9, 's'),
  ts('Node network throughput', [
    q('sum by (instance) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|lxc.*|cilium.*|vxlan.*"}[$__rate_interval]))', 'rx {{instance}}'),
    q('-sum by (instance) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*|lxc.*|cilium.*|vxlan.*"}[$__rate_interval]))', 'tx {{instance}}'),
  ], 12, 55, 12, 9, 'Bps'),

  // --- Internet ---------------------------------------------------------------
  row.new('Internet') + pos(0, 64, 24, 1),
  ts('Ping RTT', [q('probe_icmp_duration_seconds{phase="rtt"}', '{{instance}}')], 0, 65, 8, 8, 's'),
  ts('Packet loss (5m)', [q('1 - avg_over_time(probe_success{job="blackbox-internet-icmp"}[5m])', '{{instance}}')], 8, 65, 8, 8, 'percentunit'),
  ts('HTTPS probe time', [q('probe_duration_seconds{job="blackbox-internet-http"}', '{{instance}}')], 16, 65, 8, 8, 's'),

  // --- Resources --------------------------------------------------------------
  row.new('Resources') + pos(0, 73, 24, 1),
  ts('CPU', [q('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))', '{{instance}}')], 0, 74, 8, 8, 'percentunit'),
  ts('Memory', [q('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', '{{instance}}')], 8, 74, 8, 8, 'percentunit'),
  ts('Hottest sensor per node', [q('max by (instance) (node_hwmon_temp_celsius)', '{{instance}}')], 16, 74, 8, 8, 'celsius'),
  ts('Root filesystem used', [q('1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}', '{{instance}}')], 0, 82, 8, 8, 'percentunit'),
  ts('GPU busy', [q('node_drm_gpu_busy_percent', '{{instance}} {{card}}')], 8, 82, 8, 8, 'percent'),
  ts('GPU VRAM used', [q('node_drm_memory_vram_used_bytes / node_drm_memory_vram_size_bytes', '{{instance}} {{card}}')], 16, 82, 8, 8, 'percentunit'),

  // --- Storage ----------------------------------------------------------------
  row.new('Storage') + pos(0, 90, 24, 1),
  ts('PVC usage', [q('kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes', '{{namespace}}/{{persistentvolumeclaim}}')], 0, 91, 12, 9, 'percentunit'),
  ts('Longhorn storage per node', [q('longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes', '{{node}}')], 12, 91, 6, 9, 'percentunit'),
  ts('Disk temperature', [q('smartctl_device_temperature{temperature_type="current"}', '{{node}} {{device}}')], 18, 91, 6, 9, 'celsius'),
  table.new('Unhealthy Longhorn volumes')
  + table.queryOptions.withTargets([instant('longhorn_volume_robustness != 1')])
  + table.queryOptions.withTransformations([
    { id: 'organize', options: { excludeByName: { Time: true, __name__: true, container: true, endpoint: true, instance: true, job: true, namespace: true, pod: true, service: true, cluster: true } } },
  ])
  + table.standardOptions.withMappings([
    { type: 'value', options: { '0': { text: 'unknown' }, '2': { text: 'degraded', color: 'orange' }, '3': { text: 'faulted', color: 'red' } } },
  ])
  + pos(0, 100, 24, 6),

  // --- Logs -------------------------------------------------------------------
  row.new('Logs') + pos(0, 106, 24, 1),
  timeSeries.new('Log lines/s by namespace')
  + { datasource: vlogs, targets: [logsTarget('* | stats by (kubernetes.pod_namespace) rate() as lines', 'statsRange') + { legendFormat: '{{kubernetes.pod_namespace}}' }] }
  + timeSeries.options.legend.withDisplayMode('table')
  + timeSeries.options.legend.withPlacement('right')
  + pos(0, 107, 24, 8),
  logs.new('Recent errors, panics and fatals')
  + { datasource: vlogs, targets: [logsTarget('(error OR panic OR fatal) | sort by (_time desc) | limit 200', 'range')] }
  + logs.options.withShowTime(true)
  + logs.options.withWrapLogMessage(true)
  + pos(0, 115, 24, 12),
])
