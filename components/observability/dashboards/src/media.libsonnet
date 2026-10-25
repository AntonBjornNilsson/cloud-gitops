// Shared helpers for the media dashboards (media_*.jsonnet, dispatcharr.jsonnet)
// and the services overview.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';

local row = grafonnet.panel.row;
local stat = grafonnet.panel.stat;
local table = grafonnet.panel.table;
local timeSeries = grafonnet.panel.timeSeries;
local barGauge = grafonnet.panel.barGauge;
local pieChart = grafonnet.panel.pieChart;
local logs = grafonnet.panel.logs;
local prometheus = grafonnet.query.prometheus;

local vm = 'VictoriaMetrics';
local vlogs = { type: 'victoriametrics-logs-datasource', uid: 'VictoriaLogs' };

local pos(x, y, w, h) = { gridPos: { x: x, y: y, w: w, h: h } };

local q(expr, legend='') =
  prometheus.new(vm, expr)
  + prometheus.withLegendFormat(legend);

local instant(expr, refId='A') =
  prometheus.new(vm, expr)
  + prometheus.withInstant(true)
  + prometheus.withFormat('table')
  + prometheus.withRefId(refId);

local steps(s) =
  stat.standardOptions.color.withMode('thresholds')
  + stat.standardOptions.thresholds.withSteps(s);

local neutral = [{ color: 'blue', value: null }];
local upDownMappings = [
  { type: 'value', options: { '0': { text: 'DOWN', color: 'red', index: 0 }, '1': { text: 'UP', color: 'green', index: 1 } } },
];

// Labels every scrape adds; hidden in label tables.
local scrapeLabels = {
  Time: true,
  __name__: true,
  cluster: true,
  container: true,
  endpoint: true,
  instance: true,
  job: true,
  namespace: true,
  pod: true,
  prometheus: true,
  url: true,
  service: true,
};

{
  vm: vm,
  vlogs: vlogs,
  pos: pos,
  q: q,
  instant: instant,
  upDownMappings: upDownMappings,
  scrapeLabels: scrapeLabels,

  row(title, y):: row.new(title) + pos(0, y, 24, 1),

  // Stat tile. graph=true adds a sparkline.
  stat(title, expr, x, y, w=3, h=4, unit='short', thresholds=neutral, decimals=null, graph=false, desc='', noValue=null, legend='')::
    stat.new(title)
    + stat.queryOptions.withTargets([q(expr, legend)])
    + stat.options.withColorMode('background')
    + stat.options.withGraphMode(if graph then 'area' else 'none')
    + stat.standardOptions.withUnit(unit)
    + (if decimals != null then stat.standardOptions.withDecimals(decimals) else {})
    + (if desc != '' then stat.panelOptions.withDescription(desc) else {})
    + (if noValue != null then stat.standardOptions.withNoValue(noValue) else {})
    + steps(thresholds)
    + pos(x, y, w, h),

  // Stat tile showing a label (e.g. a version) instead of the value.
  textStat(title, targets, x, y, w=3, h=4, noValue='down')::
    stat.new(title)
    + stat.queryOptions.withTargets(targets)
    + stat.options.withTextMode('name')
    + stat.options.withColorMode('none')
    + stat.options.withGraphMode('none')
    + stat.options.text.withTitleSize(12)
    + stat.options.text.withValueSize(16)
    + stat.standardOptions.withNoValue(noValue)
    + pos(x, y, w, h),

  ts(title, targets, x, y, w, h, unit='short', stack=false, min=null, desc='', bars=false, legendRight=true)::
    timeSeries.new(title)
    + timeSeries.queryOptions.withTargets(targets)
    + timeSeries.standardOptions.withUnit(unit)
    + (if min != null then timeSeries.standardOptions.withMin(min) else {})
    + (if desc != '' then timeSeries.panelOptions.withDescription(desc) else {})
    + timeSeries.fieldConfig.defaults.custom.withFillOpacity(if stack || bars then 60 else 10)
    + timeSeries.fieldConfig.defaults.custom.withGradientMode('opacity')
    + timeSeries.fieldConfig.defaults.custom.withShowPoints('never')
    + (if bars then timeSeries.fieldConfig.defaults.custom.withDrawStyle('bars') else {})
    + (if stack then timeSeries.fieldConfig.defaults.custom.stacking.withMode('normal') else {})
    + timeSeries.options.legend.withDisplayMode('table')
    + timeSeries.options.legend.withPlacement(if legendRight then 'right' else 'bottom')
    + timeSeries.options.legend.withCalcs(['lastNotNull', 'max'])
    + timeSeries.options.tooltip.withMode('multi')
    + timeSeries.options.tooltip.withSort('descending')
    + pos(x, y, w, h),

  barGauge(title, targets, x, y, w, h, unit='short', thresholds=neutral, min=0, max=null, desc='')::
    barGauge.new(title)
    + barGauge.queryOptions.withTargets(targets)
    + barGauge.options.withDisplayMode('gradient')
    + barGauge.options.withOrientation('horizontal')
    + barGauge.options.withShowUnfilled(true)
    + barGauge.standardOptions.withUnit(unit)
    + barGauge.standardOptions.withMin(min)
    + (if max != null then barGauge.standardOptions.withMax(max) else {})
    + (if desc != '' then barGauge.panelOptions.withDescription(desc) else {})
    + barGauge.standardOptions.color.withMode('thresholds')
    + barGauge.standardOptions.thresholds.withSteps(thresholds)
    + pos(x, y, w, h),

  pie(title, targets, x, y, w, h, unit='short')::
    pieChart.new(title)
    + pieChart.queryOptions.withTargets(targets)
    + pieChart.options.withPieType('donut')
    + pieChart.options.reduceOptions.withCalcs(['lastNotNull'])
    + pieChart.options.legend.withDisplayMode('table')
    + pieChart.options.legend.withPlacement('right')
    + pieChart.options.legend.withValues(['value', 'percent'])
    + pieChart.standardOptions.withUnit(unit)
    + pos(x, y, w, h),

  // Table of label sets from one instant query.
  labelTable(title, expr, x, y, w, h, rename={}, exclude={}, overrides=[], desc='', sortBy=null)::
    table.new(title)
    + (if desc != '' then table.panelOptions.withDescription(desc) else {})
    + table.queryOptions.withTargets([instant(expr)])
    + table.queryOptions.withTransformations([
      { id: 'organize', options: { excludeByName: scrapeLabels + exclude, renameByName: rename } },
    ])
    + table.standardOptions.withNoValue('-')
    + table.standardOptions.withOverrides(overrides)
    + (if sortBy != null then table.options.withSortBy([sortBy]) else {})
    + pos(x, y, w, h),

  // Several instant queries reduced to the same key label, joined into one table.
  // columns: [{ expr, name, overrides? }]; the first one carries the label columns.
  joinTable(title, key, columns, x, y, w, h, rename={}, exclude={}, order={}, overrides=[], desc='', sortBy=null)::
    local refs = std.mapWithIndex(function(i, c) std.char(65 + i), columns);
    table.new(title)
    + (if desc != '' then table.panelOptions.withDescription(desc) else {})
    + table.queryOptions.withTargets(std.mapWithIndex(function(i, c) instant(c.expr, refs[i]), columns))
    + table.queryOptions.withTransformations([
      { id: 'joinByField', options: { byField: key, mode: 'outer' } },
      {
        id: 'organize',
        options: {
          excludeByName: scrapeLabels + exclude + { ['Time %d' % (i + 1)]: true for i in std.range(0, std.length(columns) - 1) }
                         + { ['Value #%s' % refs[i]]: true for i in std.range(0, std.length(columns) - 1) if columns[i].name == null },
          renameByName: rename + { ['Value #%s' % refs[i]]: columns[i].name for i in std.range(0, std.length(columns) - 1) if columns[i].name != null },
          indexByName: order,
        },
      },
    ])
    + table.standardOptions.withNoValue('-')
    + table.standardOptions.withOverrides(overrides)
    + (if sortBy != null then table.options.withSortBy([sortBy]) else {})
    + pos(x, y, w, h),

  // Field override helpers for tables.
  byName(name, props):: { matcher: { id: 'byName', options: name }, properties: props },
  unit(u):: { id: 'unit', value: u },
  width(w):: { id: 'custom.width', value: w },
  decimals(d):: { id: 'decimals', value: d },
  cell(type='color-background'):: { id: 'custom.cellOptions', value: { type: type } },
  gaugeCell:: { id: 'custom.cellOptions', value: { type: 'gauge', mode: 'lcd', valueDisplayMode: 'text' } },
  colorSteps(s):: [
    { id: 'color', value: { mode: 'thresholds' } },
    { id: 'thresholds', value: { mode: 'absolute', steps: s } },
  ],
  mappings(m):: { id: 'mappings', value: m },

  logs(title, query, x, y, w, h)::
    logs.new(title)
    + {
      datasource: vlogs,
      targets: [{ datasource: vlogs, editorMode: 'code', expr: query, queryType: 'range', refId: 'A' }],
    }
    + logs.options.withShowTime(true)
    + logs.options.withWrapLogMessage(true)
    + logs.options.withSortOrder('Descending')
    + pos(x, y, w, h),

  // LogsQL for errors/warnings in some namespaces (regex).
  errorLogs(nsRegex)::
    'kubernetes.pod_namespace:~"^(%s)$" (error OR warn OR warning OR exception OR fail OR failed OR traceback) -"level=info" | sort by (_time desc) | limit 300' % nsRegex,

  // One compact health strip (h=6) for an app in namespace `ns`:
  // availability, Traefik traffic, CPU and memory of every container in the namespace.
  serviceStrip(title, ns, y, svcRegex=null)::
    local svc = if svcRegex != null then svcRegex else ns + '-.*';
    [
      stat.new(title)
      + stat.panelOptions.withDescription('Blackbox probe through Traefik (Ingress %s). Sparkline: response time.' % ns)
      + stat.queryOptions.withTargets([q('min(probe_success{probe_group="ingress", namespace="%s"})' % ns)])
      + stat.options.withColorMode('background')
      + stat.options.withGraphMode('none')
      + stat.standardOptions.withMappings(upDownMappings)
      + stat.standardOptions.withNoValue('no probe')
      + steps([{ color: 'red', value: null }, { color: 'green', value: 1 }])
      + pos(0, y, 3, 3),
      stat.new('Restarts (24h)')
      + stat.queryOptions.withTargets([q('sum(increase(kube_pod_container_status_restarts_total{namespace="%s"}[24h])) or vector(0)' % ns)])
      + stat.options.withColorMode('background')
      + stat.options.withGraphMode('none')
      + stat.standardOptions.withDecimals(0)
      + steps([{ color: 'green', value: null }, { color: 'orange', value: 1 }, { color: 'red', value: 5 }])
      + pos(0, y + 3, 3, 3),
      self.ts('Requests/s (Traefik)', [
        q('sum by (code) (rate(traefik_service_requests_total{exported_service=~"%s"}[$__rate_interval]))' % svc, '{{code}}'),
      ], 3, y, 7, 6, 'reqps', true, 0, legendRight=false)
      + timeSeries.options.legend.withDisplayMode('list'),
      self.ts('CPU', [
        q('sum by (container) (rate(container_cpu_usage_seconds_total{namespace="%s", container!=""}[$__rate_interval]))' % ns, '{{container}}'),
      ], 10, y, 7, 6, 'cores', false, 0, legendRight=false)
      + timeSeries.options.legend.withDisplayMode('list'),
      self.ts('Memory', [
        q('sum by (container) (container_memory_working_set_bytes{namespace="%s", container!=""})' % ns, '{{container}}'),
      ], 17, y, 7, 6, 'bytes', false, 0, legendRight=false)
      + timeSeries.options.legend.withDisplayMode('list'),
    ],

  // Health issues reported by the *arr apps (exportarr), as a table.
  arrHealth(apps, x, y, w, h)::
    self.labelTable('Health checks (%s)' % std.join(', ', apps),
                    '{__name__=~"(%s)_system_health_issues"} > 0' % std.join('|', apps),
                    x, y, w, h,
                    rename={ app: 'App', type: 'Level', source: 'Check', message: 'Message' },
                    exclude={ Value: true, wikiurl: true },
                    overrides=[
                      self.byName('App', [self.width(100)]),
                      self.byName('Level', [self.width(90), self.cell('color-text'), self.mappings([
                        { type: 'value', options: { warning: { color: 'orange', index: 0 }, 'error': { color: 'red', index: 1 }, notice: { color: 'blue', index: 2 } } },
                      ])]),
                      self.byName('Check', [self.width(280)]),
                    ],
                    desc='Same as System > Status in each app. Empty = healthy.'),

  // Dropdown linking all dashboards tagged "media".
  mediaLinks:: [
    { type: 'dashboards', tags: ['media'], asDropdown: true, title: 'Media dashboards', includeVars: false, keepTime: true },
    { type: 'link', title: 'Services overview', url: '/d/services-overview', icon: 'dashboard', keepTime: true },
  ],
}
