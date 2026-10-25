// grafana-folder: Media
// Media stack, "getting" stage: requests (Seerr), indexers (Prowlarr),
// downloads (qBittorrent) and queue cleanup (Cleanuparr).
// Metrics: qbittorrent-exporter and exportarr (VMPodScrape media-exporters).
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

dashboard.new('Media · Downloads')
+ dashboard.withUid('media-downloads')
+ dashboard.withDescription('Seerr requests, Prowlarr indexers, qBittorrent downloads and Cleanuparr.')
+ dashboard.withTags(['media', 'downloads', 'qbittorrent', 'prowlarr'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withLinks(m.mediaLinks)
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('Download', 'sum(qbittorrent_global_download_speed_bytes)', 0, 1, unit='Bps', graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }]),
  m.stat('Upload', 'sum(qbittorrent_global_upload_speed_bytes)', 3, 1, unit='Bps', graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'blue', value: 1 }]),
  m.stat('Torrents', 'sum(qbittorrent_global_torrents)', 6, 1),
  m.stat('Downloading', 'sum(qbittorrent_torrent_states{name=~"downloading|forcedDL|metaDL|stalledDL|queuedDL|checkingDL"}) or vector(0)', 9, 1,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }]),
  m.stat('Global ratio', 'max(qbittorrent_global_ratio)', 12, 1, decimals=2,
         thresholds=[{ color: 'orange', value: null }, { color: 'green', value: 1 }]),
  m.stat('Connection', 'max by (connection_status) (qbittorrent_transfer_connection_status) == 1', 15, 1, legend='{{connection_status}}',
         desc='connected = incoming peers reach the VPN-forwarded port; firewalled = port forwarding is broken; disconnected = no tunnel.')
  + grafonnet.panel.stat.options.withTextMode('name')
  + grafonnet.panel.stat.standardOptions.withOverrides([
    { matcher: { id: 'byName', options: 'connected' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'green' } }] },
    { matcher: { id: 'byName', options: 'firewalled' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'orange' } }] },
    { matcher: { id: 'byName', options: 'disconnected' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'red' } }] },
  ]),
  m.stat('Free disk', 'min(qbittorrent_global_free_space_on_disk_bytes)', 18, 1, unit='bytes', graph=true,
         thresholds=[{ color: 'red', value: null }, { color: 'orange', value: 100e9 }, { color: 'green', value: 500e9 }]),
  m.stat('Indexers up', 'max(prowlarr_indexer_enabled_total) - (count(prowlarr_indexer_unavailable == 1) or vector(0))', 21, 1,
         desc='Enabled Prowlarr indexers minus the ones Prowlarr has disabled after failures.',
         thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }]),

  // --- qBittorrent --------------------------------------------------------------
  m.row('qBittorrent', 5),
  m.ts('Transfer speed', [
    q('sum(qbittorrent_global_download_speed_bytes)', 'download'),
    q('-sum(qbittorrent_global_upload_speed_bytes)', 'upload'),
  ], 0, 6, 12, 8, 'Bps'),
  m.ts('Torrents by state', [q('sum by (name) (qbittorrent_torrent_states) > 0', '{{name}}')], 12, 6, 12, 8, 'short', true, 0),
  m.joinTable('Torrents', 'name', [
    { expr: 'max by (name) (qbittorrent_torrent_progress)', name: 'Progress' },
    { expr: 'max by (name) (qbittorrent_torrent_size_bytes)', name: 'Size' },
    { expr: 'max by (name) (qbittorrent_torrent_download_speed_bytes)', name: 'Down' },
    { expr: 'max by (name) (qbittorrent_torrent_upload_speed_bytes)', name: 'Up' },
    { expr: 'max by (name) (qbittorrent_torrent_ratio)', name: 'Ratio' },
    { expr: 'max by (name) (qbittorrent_torrent_seeders)', name: 'Seeds' },
    { expr: 'max by (name) (qbittorrent_torrent_leechers)', name: 'Peers' },
    { expr: 'max by (name) (qbittorrent_torrent_eta) < 8640000', name: 'ETA' },
    { expr: 'max by (name) (qbittorrent_torrent_added_on) * 1000', name: 'Added' },
  ], 0, 14, 24, 9,
    rename={ name: 'Name' },
    overrides=[
      m.byName('Progress', [m.unit('percentunit'), m.width(160), m.gaugeCell] + m.colorSteps([{ color: 'blue', value: null }, { color: 'green', value: 1 }])),
      m.byName('Size', [m.unit('bytes'), m.width(90)]),
      m.byName('Down', [m.unit('Bps'), m.width(90)]),
      m.byName('Up', [m.unit('Bps'), m.width(90)]),
      m.byName('Ratio', [m.decimals(2), m.width(70), m.cell('color-text')] + m.colorSteps([{ color: 'orange', value: null }, { color: 'green', value: 1 }])),
      m.byName('Seeds', [m.width(70)]),
      m.byName('Peers', [m.width(70)]),
      m.byName('ETA', [m.unit('s'), m.width(90)]),
      m.byName('Added', [m.unit('dateTimeFromNow'), m.width(110)]),
    ],
    sortBy={ displayName: 'Added', desc: true },
    desc='ETA is time to completion while downloading, or to the seeding limit (1 day / ratio 1.0) while seeding.'),
  m.ts('Transferred per day', [
    q('sum(increase(qbittorrent_global_alltime_downloaded_bytes[1d]))', 'downloaded'),
    q('sum(increase(qbittorrent_global_alltime_uploaded_bytes[1d]))', 'uploaded'),
  ], 0, 23, 8, 8, 'bytes', bars=true, legendRight=false)
  + grafonnet.panel.timeSeries.queryOptions.withInterval('1d'),
  m.ts('Peers and DHT', [
    q('sum(qbittorrent_global_total_peer_connections)', 'peer connections'),
    q('sum(qbittorrent_global_dht_nodes)', 'DHT nodes'),
  ], 8, 23, 8, 8, 'short', false, 0, legendRight=false),
  m.stat('All-time downloaded', 'max(qbittorrent_global_alltime_downloaded_bytes)', 16, 23, 4, 4, 'bytes'),
  m.stat('All-time uploaded', 'max(qbittorrent_global_alltime_uploaded_bytes)', 20, 23, 4, 4, 'bytes'),
  m.stat('Version', 'max by (version) (qbittorrent_app_version)', 16, 27, 4, 4, legend='{{version}}')
  + grafonnet.panel.stat.options.withTextMode('name')
  + grafonnet.panel.stat.options.withColorMode('none'),
  m.stat('Alt. speed limits', 'max(qbittorrent_app_alt_rate_limits_enabled)', 20, 27, 4, 4,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + grafonnet.panel.stat.standardOptions.withMappings([{ type: 'value', options: { '0': { text: 'off' }, '1': { text: 'on' } } }]),

  // --- Prowlarr -----------------------------------------------------------------
  m.row('Prowlarr', 31),
  m.ts('Searches per hour by indexer', [
    q('sum by (indexer) (rate(prowlarr_indexer_queries_total[$__rate_interval])) * 3600', '{{indexer}}'),
  ], 0, 32, 8, 8, 'short', true, 0),
  m.ts('RSS syncs per hour by indexer', [
    q('sum by (indexer) (rate(prowlarr_indexer_rss_queries_total[$__rate_interval])) * 3600', '{{indexer}}'),
  ], 8, 32, 8, 8, 'short', true, 0),
  m.ts('Failures per hour', [
    q('sum by (indexer) (rate(prowlarr_indexer_failed_queries_total[$__rate_interval]) + rate(prowlarr_indexer_failed_rss_queries_total[$__rate_interval]) + rate(prowlarr_indexer_failed_grabs_total[$__rate_interval])) * 3600 > 0', '{{indexer}}'),
  ], 16, 32, 8, 8, 'short', true, 0),
  m.joinTable('Indexers', 'indexer', [
    { expr: 'max by (indexer) (prowlarr_indexer_unavailable) or (max by (indexer) (prowlarr_indexer_queries_total) * 0)', name: 'Status' },
    { expr: 'max by (indexer) (prowlarr_indexer_average_response_time_ms)', name: 'Avg response' },
    { expr: 'max by (indexer) (prowlarr_indexer_queries_total)', name: 'Searches' },
    { expr: 'max by (indexer) (prowlarr_indexer_rss_queries_total)', name: 'RSS' },
    { expr: 'max by (indexer) (prowlarr_indexer_grabs_total)', name: 'Grabs' },
    { expr: 'max by (indexer) (prowlarr_indexer_failed_queries_total + prowlarr_indexer_failed_rss_queries_total)', name: 'Failed queries' },
    { expr: 'max by (indexer) (prowlarr_indexer_failed_grabs_total)', name: 'Failed grabs' },
  ], 0, 40, 14, 8,
    rename={ indexer: 'Indexer' },
    overrides=[
      m.byName('Status', [m.width(110), m.cell(), m.mappings([
        { type: 'value', options: { '0': { text: 'OK', color: 'green', index: 0 }, '1': { text: 'Disabled', color: 'red', index: 1 } } },
      ])]),
      m.byName('Avg response', [m.unit('ms'), m.width(110), m.cell('color-text')] + m.colorSteps([{ color: 'green', value: null }, { color: 'orange', value: 2000 }, { color: 'red', value: 5000 }])),
    ],
    desc='Counters since Prowlarr started keeping stats (exportarr backfills them). Disabled = Prowlarr paused the indexer after repeated failures.'),
  m.barGauge('Grabs by indexer', [q('sort_desc(max by (indexer) (prowlarr_indexer_grabs_total))', '{{indexer}}')], 14, 40, 10, 8),
  m.arrHealth(['prowlarr'], 0, 48, 24, 5),

  // --- Services -----------------------------------------------------------------
  m.row('Pods and traffic', 53),
]
+ m.serviceStrip('qBittorrent', 'qbittorrent', 54)
+ m.serviceStrip('Prowlarr', 'prowlarr', 60)
+ m.serviceStrip('Seerr', 'jellyseerr', 66)
+ m.serviceStrip('Cleanuparr', 'cleanuparr', 72)
+ [
  m.logs('Errors and warnings', m.errorLogs('qbittorrent|prowlarr|jellyseerr|cleanuparr'), 0, 78, 24, 10),
])
