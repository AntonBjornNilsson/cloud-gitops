// grafana-folder: Media
// Dispatcharr (IPTV proxy): what is playing, stream health, provider
// connections/expiry, clients and the pod itself.
//
// Metrics come from the dispatcharr-exporter plugin (VMPodScrape dispatcharr).
// The "Clients" and "EPG sources" rows need "Include Client Statistics" /
// "Include EPG Source Metrics" enabled in the plugin settings; they stay empty
// otherwise.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local media = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;
local stat = grafonnet.panel.stat;
local table = grafonnet.panel.table;
local timeSeries = grafonnet.panel.timeSeries;
local barGauge = grafonnet.panel.barGauge;
local logs = grafonnet.panel.logs;
local prometheus = grafonnet.query.prometheus;

local vm = 'VictoriaMetrics';
local vlogs = { type: 'victoriametrics-logs-datasource', uid: 'VictoriaLogs' };

local q(expr, legend='') =
  prometheus.new(vm, expr)
  + prometheus.withLegendFormat(legend);

local instant(expr, refId) =
  prometheus.new(vm, expr)
  + prometheus.withInstant(true)
  + prometheus.withFormat('table')
  + prometheus.withRefId(refId);

local pos(x, y, w, h) = { gridPos: { x: x, y: y, w: w, h: h } };

// Per-stream metrics only carry channel_uuid/channel_number; the name lives
// on dispatcharr_stream_metadata.
local named(expr) = '(%s) * on(channel_uuid) group_left(channel_name) max by (channel_uuid, channel_name) (dispatcharr_stream_metadata)' % expr;
local streamLegend = '{{channel_number}} {{channel_name}}';

local thresholds(steps) =
  stat.standardOptions.color.withMode('thresholds')
  + stat.standardOptions.thresholds.withSteps(steps);

local statPanel(title, expr, x, steps=[{ color: 'blue', value: null }], unit='short', decimals=null) =
  stat.new(title)
  + stat.queryOptions.withTargets([q(expr)])
  + stat.options.withColorMode('background')
  + stat.options.withGraphMode('area')
  + stat.standardOptions.withUnit(unit)
  + (if decimals != null then stat.standardOptions.withDecimals(decimals) else {})
  + thresholds(steps)
  + pos(x, 1, 3, 4);

local ts(title, targets, x, y, w, h, unit='short', stack=false, min=null) =
  timeSeries.new(title)
  + timeSeries.queryOptions.withTargets(targets)
  + timeSeries.standardOptions.withUnit(unit)
  + (if min != null then timeSeries.standardOptions.withMin(min) else {})
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(if stack then 40 else 10)
  + timeSeries.fieldConfig.defaults.custom.withGradientMode('opacity')
  + timeSeries.fieldConfig.defaults.custom.withShowPoints('never')
  + (if stack then timeSeries.fieldConfig.defaults.custom.stacking.withMode('normal') else {})
  + timeSeries.options.legend.withDisplayMode('table')
  + timeSeries.options.legend.withPlacement('right')
  + timeSeries.options.legend.withCalcs(['lastNotNull', 'max'])
  + timeSeries.options.tooltip.withMode('multi')
  + timeSeries.options.tooltip.withSort('descending')
  + pos(x, y, w, h);

local byName(name, props) = { matcher: { id: 'byName', options: name }, properties: props };
local unitProp(u) = { id: 'unit', value: u };
local widthProp(w) = { id: 'custom.width', value: w };
local colorCell(mode='color-background') = { id: 'custom.cellOptions', value: { type: mode } };
local stepsProp(steps) = [
  { id: 'color', value: { mode: 'thresholds' } },
  { id: 'thresholds', value: { mode: 'absolute', steps: steps } },
];

local stateMappings = [
  { type: 'value', options: {
    active: { text: 'active', color: 'green', index: 0 },
    paused: { text: 'paused', color: 'blue', index: 1 },
    waiting_for_clients: { text: 'waiting for clients', color: 'yellow', index: 2 },
    buffering: { text: 'buffering', color: 'orange', index: 3 },
    'error': { text: 'error', color: 'red', index: 4 },
  } },
];

// Instant queries reduced to one label set per stream, then joined on channel_uuid.
local nowPlaying =
  table.new('Now playing')
  + table.panelOptions.withDescription('One row per stream Dispatcharr is pulling from a provider. Speed < 1x means the upstream delivers slower than realtime (viewers will buffer); Fallback > 0 means the primary stream failed.')
  + table.queryOptions.withTargets([
    instant('max by (channel_uuid, channel_number, channel_name, channel_group, type, state, resolution, video_codec, provider, profile_name) (dispatcharr_stream_metadata)', 'A'),
    instant('max by (channel_uuid, current_title) (dispatcharr_stream_programming)', 'B'),
    instant('max by (channel_uuid) (dispatcharr_stream_active_clients)', 'C'),
    instant('max by (channel_uuid) (dispatcharr_stream_current_bitrate_bps)', 'D'),
    instant('max by (channel_uuid) (dispatcharr_stream_fps)', 'E'),
    instant('max by (channel_uuid) (dispatcharr_stream_buffering_speed)', 'F'),
    instant('max by (channel_uuid) (dispatcharr_stream_index)', 'G'),
    instant('max by (channel_uuid) (dispatcharr_stream_uptime_seconds)', 'H'),
  ])
  + table.queryOptions.withTransformations([
    { id: 'joinByField', options: { byField: 'channel_uuid', mode: 'outer' } },
    {
      id: 'organize',
      options: {
        excludeByName: { channel_uuid: true, 'Value #A': true, 'Value #B': true }
                       + { ['Time %d' % i]: true for i in std.range(1, 8) }
                       + { Time: true },
        indexByName: {
          channel_number: 0,
          channel_name: 1,
          current_title: 2,
          channel_group: 3,
          type: 4,
          state: 5,
          'Value #C': 6,
          'Value #D': 7,
          resolution: 8,
          video_codec: 9,
          'Value #E': 10,
          'Value #F': 11,
          'Value #G': 12,
          'Value #H': 13,
          provider: 14,
          profile_name: 15,
        },
        renameByName: {
          channel_number: 'Ch',
          channel_name: 'Channel',
          current_title: 'Now showing',
          channel_group: 'Group',
          type: 'Type',
          state: 'State',
          'Value #C': 'Viewers',
          'Value #D': 'Bitrate',
          resolution: 'Resolution',
          video_codec: 'Codec',
          'Value #E': 'FPS',
          'Value #F': 'Speed',
          'Value #G': 'Fallback',
          'Value #H': 'Uptime',
          provider: 'Provider',
          profile_name: 'Profile',
        },
      },
    },
  ])
  + table.options.withSortBy([{ displayName: 'Viewers', desc: true }])
  + table.options.footer.withShow(false)
  + table.standardOptions.withNoValue('-')
  + table.fieldConfig.defaults.custom.withAlign('auto')
  + table.standardOptions.withOverrides([
    byName('Ch', [widthProp(70)]),
    byName('State', [{ id: 'mappings', value: stateMappings }, colorCell('color-text'), widthProp(150)]),
    byName('Viewers', [widthProp(80)] + stepsProp([{ color: 'text', value: null }, { color: 'green', value: 1 }]) + [colorCell('color-text')]),
    byName('Bitrate', [unitProp('bps'), widthProp(100)]),
    byName('FPS', [{ id: 'decimals', value: 0 }, widthProp(60)]),
    byName('Speed', [unitProp('x'), { id: 'decimals', value: 2 }, widthProp(80), colorCell()]
                    + stepsProp([{ color: 'red', value: null }, { color: 'orange', value: 0.9 }, { color: 'green', value: 1 }])),
    byName('Fallback', [widthProp(80), colorCell()]
                       + stepsProp([{ color: 'transparent', value: null }, { color: 'orange', value: 1 }])),
    byName('Uptime', [unitProp('s'), widthProp(100)]),
  ])
  + pos(0, 5, 24, 9);

local labelTable(title, expr, exclude, rename, x, y, w, h, desc='') =
  table.new(title)
  + (if desc != '' then table.panelOptions.withDescription(desc) else {})
  + table.queryOptions.withTargets([instant(expr, 'A')])
  + table.queryOptions.withTransformations([
    {
      id: 'organize',
      options: {
        excludeByName: { Time: true, __name__: true, job: true, instance: true, namespace: true, pod: true, container: true, endpoint: true, prometheus: true, cluster: true } + exclude,
        renameByName: rename,
      },
    },
  ])
  + table.standardOptions.withNoValue('-')
  + pos(x, y, w, h);

dashboard.new('Dispatcharr')
+ dashboard.withUid('dispatcharr')
+ dashboard.withDescription('Dispatcharr IPTV proxy: active streams and their health, provider connections and expiry, clients, and the pod.')
+ dashboard.withTags(['media', 'dispatcharr', 'iptv'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-12h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('30s')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withLinks(media.mediaLinks)
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  row.new('Overview') + pos(0, 0, 24, 1),
  stat.new('Dispatcharr')
  + stat.panelOptions.withDescription('Dispatcharr and exporter plugin versions')
  + stat.queryOptions.withTargets([
    q('max by (version) (dispatcharr_info)', 'v{{version}}'),
    q('max by (version) (dispatcharr_exporter_info)', 'exporter {{version}}'),
  ])
  + stat.options.withTextMode('name')
  + stat.options.withColorMode('none')
  + stat.options.withGraphMode('none')
  + stat.options.text.withTitleSize(12)
  + stat.options.text.withValueSize(16)
  + stat.standardOptions.withNoValue('exporter down')
  + pos(0, 1, 3, 4),
  statPanel('Active streams', 'sum(dispatcharr_active_streams{type!=""}) or vector(0)', 3,
            [{ color: 'text', value: null }, { color: 'green', value: 1 }]),
  statPanel('Viewers', 'sum(dispatcharr_stream_active_clients) or vector(0)', 6,
            [{ color: 'text', value: null }, { color: 'green', value: 1 }]),
  statPanel('Upstream bandwidth', 'sum(dispatcharr_stream_current_bitrate_bps) or vector(0)', 9,
            [{ color: 'text', value: null }, { color: 'blue', value: 1 }], 'bps'),
  stat.new('Provider connections')
  + stat.panelOptions.withDescription('Connections in use per M3U profile, against the profile limit (0 = unlimited)')
  + stat.queryOptions.withTargets([
    q('sum(dispatcharr_profile_connections)', 'used'),
    q('sum(dispatcharr_profile_max_connections) > 0', 'limit'),
  ])
  + stat.options.withColorMode('none')
  + stat.options.withGraphMode('none')
  + stat.options.withTextMode('value_and_name')
  + pos(12, 1, 3, 4),
  statPanel('Provider expires in', 'min(dispatcharr_profile_days_to_expiry >= 0)', 15,
            [{ color: 'red', value: null }, { color: 'orange', value: 14 }, { color: 'green', value: 30 }], 'd', 0)
  + stat.options.withGraphMode('none')
  + stat.standardOptions.withNoValue('n/a'),
  statPanel('Channels', 'sum(dispatcharr_channels{status="total"})', 18)
  + stat.options.withGraphMode('none'),
  statPanel('Provider streams', 'sum(dispatcharr_m3u_account_stream_count)', 21)
  + stat.options.withGraphMode('none'),

  nowPlaying,

  // --- Streams ------------------------------------------------------------------
  row.new('Streams') + pos(0, 14, 24, 1),
  ts('Active streams by type', [q('sum by (type) (dispatcharr_active_streams{type!=""})', '{{type}}')], 0, 15, 8, 8, 'short', true, 0),
  ts('Viewers per channel', [q(named('max by (channel_uuid, channel_number) (dispatcharr_stream_active_clients)'), streamLegend)], 8, 15, 16, 8, 'short', true, 0),
  ts('Bitrate per stream', [q(named('max by (channel_uuid, channel_number) (dispatcharr_stream_current_bitrate_bps)'), streamLegend)], 0, 23, 12, 8, 'bps', false, 0),
  ts('Buffering speed (live, 1x = realtime)', [q(named('max by (channel_uuid, channel_number) (dispatcharr_stream_buffering_speed)'), streamLegend)], 12, 23, 12, 8, 'x', false, 0)
  + timeSeries.panelOptions.withDescription('How fast the upstream is read relative to realtime. Below 1x the stream falls behind and viewers buffer.')
  + timeSeries.fieldConfig.defaults.custom.thresholdsStyle.withMode('line+area')
  + timeSeries.standardOptions.color.withMode('palette-classic')
  + timeSeries.standardOptions.thresholds.withMode('absolute')
  + timeSeries.standardOptions.thresholds.withSteps([{ color: 'red', value: null }, { color: 'transparent', value: 1 }]),
  ts('FPS per stream', [q(named('max by (channel_uuid, channel_number) (dispatcharr_stream_fps)'), streamLegend)], 0, 31, 12, 8, 'short', false, 0),
  ts('Fallback stream index (0 = primary)', [q(named('max by (channel_uuid, channel_number) (dispatcharr_stream_index)'), streamLegend)], 12, 31, 12, 8, 'short', false, 0)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
  + timeSeries.fieldConfig.defaults.custom.withLineInterpolation('stepAfter'),

  // --- Providers ----------------------------------------------------------------
  row.new('Providers') + pos(0, 39, 24, 1),
  ts('Provider connections', [
    q('sum by (account_name, profile_name) (dispatcharr_profile_connections)', 'used {{account_name}} / {{profile_name}}'),
    q('sum by (account_name, profile_name) (dispatcharr_profile_max_connections) > 0', 'limit {{account_name}} / {{profile_name}}'),
  ], 0, 40, 12, 8, 'short', false, 0)
  + timeSeries.standardOptions.withOverrides([
    { matcher: { id: 'byRegexp', options: '^limit .*' }, properties: [
      { id: 'custom.lineStyle', value: { fill: 'dash', dash: [10, 10] } },
      { id: 'custom.fillOpacity', value: 0 },
      { id: 'color', value: { mode: 'fixed', fixedColor: 'red' } },
    ] },
  ]),
  barGauge.new('Days until provider expiry')
  + barGauge.queryOptions.withTargets([
    q('max by (account_name, profile_name) (dispatcharr_profile_days_to_expiry >= 0)', '{{account_name}} / {{profile_name}}'),
  ])
  + barGauge.options.withDisplayMode('gradient')
  + barGauge.options.withOrientation('horizontal')
  + barGauge.standardOptions.withUnit('d')
  + barGauge.standardOptions.withMin(0)
  + barGauge.standardOptions.withMax(365)
  + barGauge.standardOptions.color.withMode('thresholds')
  + barGauge.standardOptions.thresholds.withSteps([{ color: 'red', value: null }, { color: 'orange', value: 14 }, { color: 'green', value: 30 }])
  + barGauge.standardOptions.withNoValue('no expiry reported')
  + pos(12, 40, 12, 8),
  labelTable('M3U accounts',
             'max by (account_name, account_type, status, is_active) (dispatcharr_m3u_account_stream_count)',
             {}, { account_name: 'Account', account_type: 'Type', status: 'Last refresh', is_active: 'Active', Value: 'Streams' },
             0, 48, 12, 6)
  + table.standardOptions.withOverrides([
    byName('Last refresh', [colorCell('color-text'), { id: 'mappings', value: [
      { type: 'value', options: {
        success: { color: 'green', index: 0 },
        'error': { color: 'red', index: 1 },
        fetching: { color: 'blue', index: 2 },
        parsing: { color: 'blue', index: 3 },
        pending_setup: { color: 'orange', index: 4 },
        disabled: { color: 'text', index: 5 },
      } },
    ] }]),
  ]),
  ts('Library size', [
    q('sum(dispatcharr_channels{status="total"})', 'channels'),
    q('sum(dispatcharr_channel_groups)', 'channel groups'),
    q('sum by (account_name) (dispatcharr_m3u_account_stream_count)', 'streams {{account_name}}'),
  ], 12, 48, 12, 6, 'short'),
  labelTable('EPG sources',
             'max by (source_name, source_type, status, is_active) (dispatcharr_epg_source_priority)',
             {}, { source_name: 'Source', source_type: 'Type', status: 'Status', is_active: 'Active', Value: 'Priority' },
             0, 54, 24, 6,
             'Needs "Include EPG Source Metrics" in the exporter plugin settings.'),

  // --- Clients ------------------------------------------------------------------
  row.new('Clients (needs "Include Client Statistics")') + pos(0, 60, 24, 1),
  table.new('Connected clients')
  + table.queryOptions.withTargets([
    instant('max by (client_id, channel_uuid, channel_number, type, ip_address, user_agent, username) (dispatcharr_client_info) * on(channel_uuid) group_left(channel_name) max by (channel_uuid, channel_name) (dispatcharr_stream_metadata)', 'A'),
    instant('max by (client_id) (dispatcharr_client_connection_duration_seconds)', 'B'),
    instant('max by (client_id) (dispatcharr_client_current_transfer_rate_bps)', 'C'),
    instant('max by (client_id) (dispatcharr_client_bytes_sent)', 'D'),
  ])
  + table.queryOptions.withTransformations([
    { id: 'joinByField', options: { byField: 'client_id', mode: 'outer' } },
    {
      id: 'organize',
      options: {
        excludeByName: { Time: true, 'Time 1': true, 'Time 2': true, 'Time 3': true, 'Time 4': true, client_id: true, channel_uuid: true, 'Value #A': true },
        indexByName: { channel_number: 0, channel_name: 1, type: 2, username: 3, ip_address: 4, user_agent: 5, 'Value #B': 6, 'Value #C': 7, 'Value #D': 8 },
        renameByName: { channel_number: 'Ch', channel_name: 'Channel', type: 'Type', username: 'User', ip_address: 'IP', user_agent: 'User agent', 'Value #B': 'Connected for', 'Value #C': 'Rate', 'Value #D': 'Sent' },
      },
    },
  ])
  + table.standardOptions.withNoValue('-')
  + table.standardOptions.withOverrides([
    byName('Ch', [widthProp(70)]),
    byName('Connected for', [unitProp('s'), widthProp(120)]),
    byName('Rate', [unitProp('bps'), widthProp(100)]),
    byName('Sent', [unitProp('bytes'), widthProp(100)]),
  ])
  + pos(0, 61, 24, 8),
  ts('Transfer rate per client', [
    q('max by (client_id, channel_uuid, channel_number) (dispatcharr_client_current_transfer_rate_bps) * on(client_id) group_left(ip_address, username) max by (client_id, ip_address, username) (dispatcharr_client_info) * on(channel_uuid) group_left(channel_name) max by (channel_uuid, channel_name) (dispatcharr_stream_metadata)', '{{username}} {{ip_address}}: {{channel_name}}'),
  ], 0, 69, 24, 8, 'bps', true, 0),

  // --- Pod ----------------------------------------------------------------------
  row.new('Pod') + pos(0, 77, 24, 1),
  ts('CPU by container', [q('sum by (pod, container) (rate(container_cpu_usage_seconds_total{namespace="dispatcharr", container!=""}[$__rate_interval]))', '{{container}}')], 0, 78, 8, 8, 'cores', false, 0),
  ts('Memory by container', [q('sum by (pod, container) (container_memory_working_set_bytes{namespace="dispatcharr", container!=""})', '{{container}}')], 8, 78, 8, 8, 'bytes', false, 0),
  ts('Network (web pod: VPN + clients)', [
    q('sum by (pod) (rate(container_network_receive_bytes_total{namespace="dispatcharr", pod=~"dispatcharr-web-.*"}[$__rate_interval])) * 8', 'rx'),
    q('-sum by (pod) (rate(container_network_transmit_bytes_total{namespace="dispatcharr", pod=~"dispatcharr-web-.*"}[$__rate_interval])) * 8', 'tx'),
  ], 16, 78, 8, 8, 'bps'),
  ts('Container restarts', [q('sum by (container) (increase(kube_pod_container_status_restarts_total{namespace="dispatcharr"}[$__rate_interval])) > 0', '{{container}}')], 0, 86, 8, 8, 'short', false, 0)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('bars'),
  logs.new('Errors and warnings')
  + { datasource: vlogs, targets: [{
    datasource: vlogs,
    editorMode: 'code',
    expr: 'kubernetes.pod_namespace:="dispatcharr" (error OR warning OR exception OR traceback) | sort by (_time desc) | limit 200',
    queryType: 'range',
    refId: 'A',
  }] }
  + logs.options.withShowTime(true)
  + logs.options.withWrapLogMessage(true)
  + logs.options.withSortOrder('Descending')
  + pos(8, 86, 16, 8),
])
