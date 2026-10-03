local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';

local dashboard = grafonnet.dashboard;
local stat = grafonnet.panel.stat;
local timeSeries = grafonnet.panel.timeSeries;
local prometheus = grafonnet.query.prometheus;

dashboard.new('Kubernetes Cluster & Services Overview')
+ dashboard.withUid('k8s-cluster-overview')
+ dashboard.withDescription('Production cluster metrics, hardware utilization, service health, and Traefik ingress performance.')
+ dashboard.withTags(['kubernetes', 'gitops', 'infrastructure', 'services'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-1h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('30s')
+ dashboard.withPanels([
  // Row 1: Key Cluster Status
  stat.new('Ready Nodes')
  + stat.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum(kube_node_status_condition{condition="Ready",status="true"} == 1)')
    + prometheus.withLegendFormat('Ready Nodes'),
  ])
  + { gridPos: { x: 0, y: 0, w: 6, h: 4 } }
  + stat.options.withColorMode('value')
  + stat.standardOptions.color.withMode('thresholds')
  + stat.standardOptions.thresholds.withSteps([
    { color: 'red', value: null },
    { color: 'green', value: 1 },
  ]),

  stat.new('Running Pods')
  + stat.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum(kube_pod_status_phase{phase="Running"})')
    + prometheus.withLegendFormat('Running Pods'),
  ])
  + { gridPos: { x: 6, y: 0, w: 6, h: 4 } }
  + stat.options.withColorMode('value')
  + stat.standardOptions.color.withMode('palette-classic'),

  stat.new('Failing / CrashLooping Pods')
  + stat.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum(kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|Error"}) or vector(0)')
    + prometheus.withLegendFormat('Failing Pods'),
  ])
  + { gridPos: { x: 12, y: 0, w: 6, h: 4 } }
  + stat.options.withColorMode('value')
  + stat.standardOptions.color.withMode('thresholds')
  + stat.standardOptions.thresholds.withSteps([
    { color: 'green', value: null },
    { color: 'red', value: 1 },
  ]),

  stat.new('Traefik Total Request Rate')
  + stat.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'round(sum(rate(traefik_service_requests_total[5m])) or sum(rate(traefik_entrypoint_requests_total[5m])) or vector(0), 0.1)')
    + prometheus.withLegendFormat('req/s'),
  ])
  + { gridPos: { x: 18, y: 0, w: 6, h: 4 } }
  + stat.standardOptions.withUnit('reqps')
  + stat.options.withColorMode('value'),

  // Row 2: CPU & Memory Utilization
  timeSeries.new('Node CPU Utilization (%)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)')
    + prometheus.withLegendFormat('{{instance}}'),
  ])
  + { gridPos: { x: 0, y: 4, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('percent')
  + timeSeries.standardOptions.withMin(0)
  + timeSeries.standardOptions.withMax(100),

  timeSeries.new('Node Memory Utilization (%)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))')
    + prometheus.withLegendFormat('{{instance}}'),
  ])
  + { gridPos: { x: 12, y: 4, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('percent')
  + timeSeries.standardOptions.withMin(0)
  + timeSeries.standardOptions.withMax(100),

  // Row 3: Service & Ingress Performance
  timeSeries.new('Traefik Requests by Service (req/s)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (exported_service) (rate(traefik_service_requests_total[5m]))')
    + prometheus.withLegendFormat('{{exported_service}}'),
  ])
  + { gridPos: { x: 0, y: 12, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('reqps'),

  timeSeries.new('Traefik HTTP Error Codes (4xx / 5xx)')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (code, exported_service) (rate(traefik_service_requests_total{code=~"[45].."}[5m]))')
    + prometheus.withLegendFormat('{{code}} - {{exported_service}}'),
  ])
  + { gridPos: { x: 12, y: 12, w: 12, h: 8 } }
  + timeSeries.standardOptions.withUnit('reqps'),

  // Row 4: Longhorn Storage Usage
  timeSeries.new('Longhorn Volume Storage Actual Usage')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (volume) (longhorn_volume_actual_size_bytes)')
    + prometheus.withLegendFormat('{{volume}}'),
  ])
  + { gridPos: { x: 0, y: 20, w: 24, h: 8 } }
  + timeSeries.standardOptions.withUnit('bytes'),
])
