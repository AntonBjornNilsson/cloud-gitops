// grafana-folder: Platform
// Power: CPU energy per node, namespace and pod from Kepler
// (components/observability/kepler, VMPodScrape kepler).
// Kepler reads the CPUs' RAPL counters. The "package" zone is the whole CPU
// socket (cores, cache, memory controller, integrated GPU); "core" is a part
// of it, so panels use zone="package" (never a sum over zones). Newer Intel
// CPUs also report "psys" (whole platform), shown in its own panel. Disks,
// fans and PSU losses are not measured: wall power is higher.
// Only the active (above idle) part is split over workloads; what is left
// after the pods is host processes (k0s, kubelet, containerd) and the kernel.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local pkg = 'zone="package"';
local node = 'kepler_node_cpu_watts{%s}' % pkg;
local pods = 'kepler_pod_cpu_watts{%s, state="running"}' % pkg;
// joules -> watt-hours
local wh(expr) = '(%s) / 3600' % expr;

dashboard.new('Power')
+ dashboard.withUid('power')
+ dashboard.withDescription('CPU power and energy per node, namespace and pod (Kepler, RAPL package zone).')
+ dashboard.withTags(['power', 'kepler', 'hardware'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('CPU power now', 'sum(%s)' % node, 0, 1, w=4, unit='watt', decimals=1, graph=true,
         desc='Sum of the RAPL package power of all nodes. Wall power is higher (disks, fans, PSU).'),
  m.stat('Energy, last 24h', wh('sum(increase(kepler_node_cpu_joules_total{%s}[24h]))' % pkg), 4, 1, w=4,
         unit='watth', decimals=0),
  m.stat('Energy, time range', wh('sum(increase(kepler_node_cpu_joules_total{%s}[$__range]))' % pkg), 8, 1, w=4,
         unit='watth', decimals=0),
  m.stat('Per year at 7d average', 'avg_over_time(sum(%s)[7d:5m]) * 8.766' % node, 12, 1, w=4,
         unit='kwatth', decimals=0,
         desc='Average CPU power over the last 7 days, times the hours in a year.'),
  m.stat('Idle share', 'sum(kepler_node_cpu_idle_watts{%s}) / sum(%s)' % [pkg, node], 16, 1, w=4,
         unit='percentunit', decimals=0,
         desc='Part of the CPU power the nodes draw when idle. This part is not split over workloads.'),
  m.stat('Pods measured', 'count(%s)' % pods, 20, 1, w=4,
         thresholds=[{ color: 'red', value: null }, { color: 'blue', value: 1 }],
         desc='Running pods that Kepler attributes power to. 0 means Kepler cannot map processes to pods.'),

  // --- Nodes ------------------------------------------------------------------
  m.row('Nodes', 5),
  m.ts('CPU power by node', [
    q('sum by (node_name) (%s)' % node, '{{node_name}}'),
  ], 0, 6, 12, 8, 'watt', stack=true, min=0),
  m.ts('Active and idle (all nodes)', [
    q('sum(kepler_node_cpu_active_watts{%s})' % pkg, 'active'),
    q('sum(kepler_node_cpu_idle_watts{%s})' % pkg, 'idle'),
  ], 12, 6, 12, 8, 'watt', stack=true, min=0, legendRight=false,
    desc='Idle is the power at the lowest load Kepler has seen; active is the rest.'),
  m.barGauge('Energy by node (time range)', [
    q(wh('sort_desc(sum by (node_name) (increase(kepler_node_cpu_joules_total{%s}[$__range])))' % pkg), '{{node_name}}'),
  ], 0, 14, 12, 7, 'watth'),
  m.ts('Host processes and kernel (not in pods)', [
    q('sum by (node_name) (kepler_node_cpu_active_watts{%s}) - sum by (node_name) (%s)' % [pkg, pods], '{{node_name}}'),
  ], 12, 14, 12, 7, 'watt', min=0, legendRight=false,
    desc='Active power not attributed to a pod: the k0s control plane and etcd, kubelet, containerd, systemd and the kernel.'),

  m.ts('Platform power (psys), where the CPU reports it', [
    q('sum by (node_name) (kepler_node_cpu_watts{zone="psys"})', '{{node_name}} platform'),
    q('sum by (node_name) (kepler_node_cpu_watts{zone="package"}) and on (node_name) kepler_node_cpu_watts{zone="psys"}', '{{node_name}} package'),
  ], 0, 21, 24, 8, 'watt', min=0,
    desc='psys is the whole platform as the CPU sees it (package plus chipset, memory and other SoC rails), closer to wall power than the package zone. Only newer Intel CPUs report it; nodes without it are left out. Disks, fans and PSU losses are still not included.'),

  // --- Workloads --------------------------------------------------------------
  m.row('Workloads', 29),
  m.ts('CPU power by namespace (top 10)', [
    q('topk(10, sum by (pod_namespace) (%s))' % pods, '{{pod_namespace}}'),
  ], 0, 30, 12, 9, 'watt', stack=true, min=0),
  m.barGauge('Energy by namespace (time range)', [
    q(wh('sort_desc(topk(15, sum by (pod_namespace) (increase(kepler_pod_cpu_joules_total{%s}[$__range]))))' % pkg), '{{pod_namespace}}'),
  ], 12, 30, 12, 9, 'watth',
    desc='Energy of pods that still exist at the end of the range; deleted pods drop out.'),
  m.ts('CPU power by pod (top 10)', [
    q('topk(10, sum by (pod_namespace, pod_name) (%s))' % pods, '{{pod_namespace}}/{{pod_name}}'),
  ], 0, 39, 12, 9, 'watt', min=0),
  m.labelTable('Top pods now',
               'topk(20, sum by (pod_namespace, pod_name, node_name) (%s))' % pods,
               12, 39, 12, 9,
               rename={ pod_namespace: 'Namespace', pod_name: 'Pod', node_name: 'Node', Value: 'Watts' },
               overrides=[{ matcher: { id: 'byName', options: 'Watts' }, properties: [{ id: 'unit', value: 'watt' }, { id: 'decimals', value: 2 }] }],
               sortBy={ displayName: 'Watts', desc: true }),
])
