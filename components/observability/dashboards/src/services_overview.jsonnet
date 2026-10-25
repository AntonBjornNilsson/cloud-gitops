// grafana-folder: Services
// One page for every user app in services/: is it up, how busy is it, what is
// it costing, and is anything about to break. Infrastructure lives in
// Homelab Overview and the Kubernetes/Platform folders.
//
// The service list is read from services/kustomization.yaml when the dashboard
// is generated (enabled lines only), so re-run generate.sh after enabling or
// disabling a service. Namespace = last path element unless listed in nsOverride.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local stat = grafonnet.panel.stat;
local stateTimeline = grafonnet.panel.stateTimeline;
local q = m.q;

local nsOverride = { 'demo/example': 'nginx-echo-namespace' };

local categoryNames = {
  ai: 'AI',
  demo: 'Demo',
  'game-servers': 'Game servers',
  'home-automation': 'Home automation',
  management: 'Management',
  security: 'Security',
  'media/getting': 'Media · Downloads',
  'media/sorting': 'Media · Library',
  'media/playing': 'Media · Playback',
};

local kustomization = importstr '../../../../services/kustomization.yaml';
local services = [
  local path = std.stripChars(std.substr(l, 3, std.length(l)), ' ');
  local parts = std.split(path, '/');
  local cat = std.join('/', parts[:std.length(parts) - 1]);
  {
    path: path,
    ns: if std.objectHas(nsOverride, path) then nsOverride[path] else parts[std.length(parts) - 1],
    category: if std.objectHas(categoryNames, cat) then categoryNames[cat] else cat,
  }
  for l in std.split(kustomization, '\n')
  if std.startsWith(l, '  - ')
];

// Longest first so a namespace that prefixes another never wins the regex.
local byLength = std.sort(services, function(s) -std.length(s.ns));
local nsRe = std.join('|', [s.ns for s in byLength]);
local nsSel = 'namespace=~"%s"' % nsRe;

// Traefik names services "<namespace>-<service>-<port>@kubernetes".
local traefik(metric, extra='') =
  'label_replace(%s{exported_service=~"(%s)-.*"%s}, "namespace", "$1", "exported_service", "(%s)-.*")' % [metric, nsRe, extra, nsRe];

// One series per service, carrying its category, so every service gets a row.
local catalog = std.join(' or ', [
  'label_replace(label_replace(vector(1), "namespace", "%s", "", ""), "category", "%s", "", "")' % [s.ns, s.category]
  for s in services
]);

local mediaLink(title, uid) = { title: title, url: '/d/%s?${__url_time_range}' % uid };

dashboard.new('Services Overview')
+ dashboard.withUid('services-overview')
+ dashboard.withDescription('Every app under services/: availability, traffic, resources, restarts, storage and alerts, plus a media summary.')
+ dashboard.withTags(['services', 'overview'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withLinks([
  { type: 'dashboards', tags: ['media'], asDropdown: true, title: 'Media dashboards', includeVars: false, keepTime: true },
  { type: 'link', title: 'Homelab overview', url: '/d/homelab-overview', icon: 'dashboard', keepTime: true },
])
+ dashboard.withPanels([
  // --- Status -------------------------------------------------------------------
  m.row('Status (%d services)' % std.length(services), 0),
  m.stat('Endpoints up', 'count(probe_success{probe_group="ingress", %s} == 1) / count(probe_success{probe_group="ingress", %s})' % [nsSel, nsSel], 0, 1,
         unit='percentunit', thresholds=[{ color: 'red', value: null }, { color: 'orange', value: 0.9 }, { color: 'green', value: 1 }],
         desc='Share of service Ingresses answering the blackbox probe.'),
  m.stat('Services down', 'count(min by (namespace) (probe_success{probe_group="ingress", %s}) == 0) or vector(0)' % nsSel, 3, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'red', value: 1 }]),
  m.stat('Pods not ready', 'count((kube_pod_status_ready{condition="false", %s} == 1) * on(namespace, pod) group_left() (kube_pod_status_phase{phase=~"Running|Pending"} == 1)) or vector(0)' % [nsSel], 6, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }],
         desc='Running or pending pods that are not Ready (finished job pods are ignored).'),
  m.stat('Restarts (24h)', 'sum(increase(kube_pod_container_status_restarts_total{%s}[24h])) or vector(0)' % nsSel, 9, 1, decimals=0,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }, { color: 'red', value: 10 }]),
  m.stat('Alerts firing', 'count(ALERTS{alertstate="firing", severity=~"warning|critical", %s}) or vector(0)' % nsSel, 12, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }],
         desc='Warning and critical alerts carrying a service namespace.'),
  m.stat('Requests/s', 'sum(rate(traefik_service_requests_total{exported_service=~"(%s)-.*"}[$__rate_interval]))' % nsRe, 15, 1, unit='reqps', graph=true),
  m.stat('CPU', 'sum(rate(container_cpu_usage_seconds_total{container!="", %s}[$__rate_interval]))' % nsSel, 18, 1, unit='cores', graph=true, decimals=2),
  m.stat('Memory', 'sum(container_memory_working_set_bytes{container!="", %s})' % nsSel, 21, 1, unit='bytes', graph=true),

  m.joinTable('Services', 'namespace', [
    { expr: catalog, name: null },
    { expr: 'min by (namespace) (probe_success{probe_group="ingress", %s})' % nsSel, name: 'Status' },
    { expr: 'max by (namespace) (avg_over_time(probe_duration_seconds{probe_group="ingress", %s}[5m]))' % nsSel, name: 'Response' },
    { expr: 'avg by (namespace) (avg_over_time(probe_success{probe_group="ingress", %s}[24h]))' % nsSel, name: 'Uptime 24h' },
    { expr: 'sum by (namespace) (rate(%s[5m]))' % traefik('traefik_service_requests_total'), name: 'Req/s' },
    { expr: 'sum by (namespace) (rate(%s[5m]))' % traefik('traefik_service_requests_total', ', code=~"5.."'), name: '5xx/s' },
    { expr: 'sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="", %s}[5m]))' % nsSel, name: 'CPU' },
    { expr: 'sum by (namespace) (container_memory_working_set_bytes{container!="", %s})' % nsSel, name: 'Memory' },
    { expr: 'sum by (namespace) (increase(kube_pod_container_status_restarts_total{%s}[24h]))' % nsSel, name: 'Restarts 24h' },
    { expr: 'max by (namespace) (kubelet_volume_stats_used_bytes{%s} / kubelet_volume_stats_capacity_bytes{%s})' % [nsSel, nsSel], name: 'Fullest PVC' },
    { expr: 'count by (namespace) (ALERTS{alertstate="firing", severity=~"warning|critical", %s})' % nsSel, name: 'Alerts' },
  ], 0, 5, 24, 16,
    rename={ namespace: 'Service', category: 'Category' },
    order={ category: 0, namespace: 1 },
    overrides=[
      m.byName('Category', [m.width(150)]),
      m.byName('Service', [m.width(170)]),
      m.byName('Status', [m.width(80), m.cell(), m.mappings(m.upDownMappings + [
        { type: 'special', options: { match: 'null', result: { text: 'no ingress', color: 'transparent', index: 2 } } },
      ])]),
      m.byName('Response', [m.unit('s'), m.width(90), m.cell('color-text')] + m.colorSteps([{ color: 'green', value: null }, { color: 'orange', value: 0.5 }, { color: 'red', value: 2 }])),
      m.byName('Uptime 24h', [m.unit('percentunit'), m.decimals(2), m.width(100), m.cell('color-text')] + m.colorSteps([{ color: 'red', value: null }, { color: 'orange', value: 0.99 }, { color: 'green', value: 0.999 }])),
      m.byName('Req/s', [m.unit('reqps'), m.decimals(2), m.width(80)]),
      m.byName('5xx/s', [m.unit('reqps'), m.decimals(2), m.width(80), m.cell('color-text')] + m.colorSteps([{ color: 'text', value: null }, { color: 'red', value: 0.01 }])),
      m.byName('CPU', [m.unit('cores'), m.decimals(2), m.width(80)]),
      m.byName('Memory', [m.unit('bytes'), m.width(90)]),
      m.byName('Restarts 24h', [m.decimals(0), m.width(100), m.cell()] + m.colorSteps([{ color: 'transparent', value: null }, { color: 'orange', value: 1 }, { color: 'red', value: 5 }])),
      m.byName('Fullest PVC', [m.unit('percentunit'), m.width(130), m.gaugeCell] + m.colorSteps([{ color: 'green', value: null }, { color: 'orange', value: 0.8 }, { color: 'red', value: 0.9 }])),
      m.byName('Alerts', [m.width(70), m.cell()] + m.colorSteps([{ color: 'transparent', value: null }, { color: 'orange', value: 1 }])),
    ],
    sortBy={ displayName: 'Category', desc: false },
    desc='One row per enabled service. Status/Response/Uptime come from the blackbox probe through Traefik; services without an Ingress show "no ingress".'),

  // --- Media at a glance ---------------------------------------------------------
  m.row('Media at a glance', 21),
  m.stat('Watching (Jellyfin)', 'count(jellyfin_now_playing_state) or vector(0)', 0, 22, graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Playback', 'media-playback')]),
  m.stat('Live TV streams', 'sum(dispatcharr_active_streams{type!=""}) or vector(0)', 3, 22, graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Dispatcharr', 'dispatcharr')]),
  m.stat('Downloading', 'sum(qbittorrent_global_download_speed_bytes)', 6, 22, unit='Bps', graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Downloads', 'media-downloads')]),
  m.stat('Missing episodes', 'max(sonarr_episode_missing_total)', 9, 22,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Library', 'media-library')]),
  m.stat('Missing movies', 'max(radarr_movie_missing_total)', 12, 22,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Library', 'media-library')]),
  m.stat('Indexers disabled', 'count(prowlarr_indexer_unavailable == 1) or vector(0)', 15, 22,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Downloads', 'media-downloads')]),
  m.stat('*arr health issues', 'count({__name__=~"(sonarr|radarr|prowlarr|bazarr)_system_health_issues"} > 0) or vector(0)', 18, 22,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + stat.panelOptions.withLinks([mediaLink('Media · Library', 'media-library')]),
  m.stat('Media disk free', 'min(qbittorrent_global_free_space_on_disk_bytes)', 21, 22, unit='bytes', graph=true,
         thresholds=[{ color: 'red', value: null }, { color: 'orange', value: 100e9 }, { color: 'green', value: 500e9 }]),

  // --- Trends ---------------------------------------------------------------------
  m.row('Trends', 26),
  stateTimeline.new('Availability')
  + stateTimeline.queryOptions.withTargets([q('min by (namespace) (probe_success{probe_group="ingress", %s})' % nsSel, '{{namespace}}')])
  + stateTimeline.standardOptions.withMappings(m.upDownMappings)
  + stateTimeline.options.withShowValue('never')
  + stateTimeline.options.withRowHeight(0.8)
  + stateTimeline.options.legend.withShowLegend(false)
  + m.pos(0, 27, 12, 12),
  m.ts('Response time (probe)', [q('max by (namespace) (probe_duration_seconds{probe_group="ingress", %s})' % nsSel, '{{namespace}}')], 12, 27, 12, 12, 's', false, 0),
  m.ts('Requests/s by service', [q('sum by (namespace) (rate(%s[$__rate_interval])) > 0' % traefik('traefik_service_requests_total'), '{{namespace}}')], 0, 39, 12, 9, 'reqps', true, 0),
  m.ts('5xx/s by service', [q('sum by (namespace, code) (rate(%s[$__rate_interval])) > 0' % traefik('traefik_service_requests_total', ', code=~"5.."'), '{{namespace}} {{code}}')], 12, 39, 12, 9, 'reqps', false, 0),
  m.ts('CPU by service', [q('sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="", %s}[$__rate_interval]))' % nsSel, '{{namespace}}')], 0, 48, 12, 9, 'cores', true, 0),
  m.ts('Memory by service', [q('sum by (namespace) (container_memory_working_set_bytes{container!="", %s})' % nsSel, '{{namespace}}')], 12, 48, 12, 9, 'bytes', true, 0),
  m.ts('Restarts', [q('sum by (namespace, container) (increase(kube_pod_container_status_restarts_total{%s}[$__rate_interval])) > 0' % nsSel, '{{namespace}}/{{container}}')], 0, 57, 12, 8, 'short', false, 0, bars=true),
  m.barGauge('PVC usage', [q('sort_desc(max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{%s} / kubelet_volume_stats_capacity_bytes{%s}))' % [nsSel, nsSel], '{{namespace}}/{{persistentvolumeclaim}}')],
             12, 57, 12, 8, 'percentunit',
             thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 0.8 }, { color: 'red', value: 0.9 }], max=1),
  m.labelTable('Firing alerts', 'sort_desc(ALERTS{alertstate="firing", severity=~"warning|critical", %s})' % nsSel, 0, 65, 24, 8,
               rename={ alertname: 'Alert', severity: 'Severity', namespace: 'Service' },
               exclude={ Value: true, alertstate: true, alertgroup: true, namespace: false },
               overrides=[m.byName('Severity', [m.width(90), m.cell('color-text'), m.mappings([
                 { type: 'value', options: { critical: { color: 'red', index: 0 }, warning: { color: 'orange', index: 1 }, info: { color: 'blue', index: 2 } } },
               ])])]),
  m.logs('Errors and warnings (all services)', m.errorLogs(nsRe), 0, 73, 24, 10),
])
