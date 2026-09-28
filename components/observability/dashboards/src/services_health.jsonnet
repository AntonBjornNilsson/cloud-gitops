local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;
local prometheus = grafonnet.query.prometheus;

dashboard.new('Kubernetes Workloads & Services Health')
+ dashboard.withUid('k8s-services-health')
+ dashboard.withDescription('Detailed CPU, memory, restarts, and network metrics for application pods and workloads.')
+ dashboard.withTags(['kubernetes', 'services', 'workloads', 'gitops'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-1h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('30s')
+ dashboard.withPanels([
  // Row 1: CPU & Memory per Namespace
  timeSeries.new('CPU Usage by Namespace (cores)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))')
    + prometheus.withLegendFormat('{{namespace}}'),
  ])
  + { gridPos: { x: 0, y: 0, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('cores'),

  timeSeries.new('Memory Usage by Namespace (bytes)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (namespace) (container_memory_working_set_bytes{container!=""})')
    + prometheus.withLegendFormat('{{namespace}}'),
  ])
  + { gridPos: { x: 12, y: 0, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('bytes'),

  // Row 2: Restarts & Network
  timeSeries.new('Container Restarts by Pod')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0')
    + prometheus.withLegendFormat('{{namespace}} / {{pod}}'),
  ])
  + { gridPos: { x: 0, y: 8, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('short'),

  timeSeries.new('Pod Network Traffic (Receive / Transmit)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (namespace) (rate(container_network_receive_bytes_total[5m]))')
    + prometheus.withLegendFormat('rx: {{namespace}}'),
    prometheus.new('VictoriaMetrics', 'sum by (namespace) (rate(container_network_transmit_bytes_total[5m]))')
    + prometheus.withLegendFormat('tx: {{namespace}}'),
  ])
  + { gridPos: { x: 12, y: 8, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('Bps'),
])
