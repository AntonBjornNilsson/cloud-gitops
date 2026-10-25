// grafana-folder: Media
// Media stack, "playing" stage: Jellyfin (sessions, transcodes, libraries,
// users, scheduled tasks) and Tracearr. Live TV has its own dashboard (Dispatcharr).
// Metrics: jellyfin-exporter (VMPodScrape media-exporters).
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local sessionLabels = 'session_id, username, device, type, title, series_title, series_season, series_episode, method';

dashboard.new('Media · Playback')
+ dashboard.withUid('media-playback')
+ dashboard.withDescription('Jellyfin: who is watching what, transcodes, libraries, users, scheduled tasks and storage; Tracearr.')
+ dashboard.withTags(['media', 'playback', 'jellyfin'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withLinks(m.mediaLinks)
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.textStat('Jellyfin', [
    q('max by (version) (jellyfin_system_info)', 'v{{version}}'),
    q('max by (version) (jellyfin_exporter_build_info)', 'exporter {{version}}'),
  ], 0, 1),
  m.stat('Server', 'max(jellyfin_up)', 3, 1, thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }], noValue='exporter down')
  + grafonnet.panel.stat.standardOptions.withMappings(m.upDownMappings),
  m.stat('Watching now', 'count(jellyfin_now_playing_state) or vector(0)', 6, 1, graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'green', value: 1 }]),
  m.stat('Transcoding', 'max(jellyfin_transcoding_active)', 9, 1, graph=true,
         thresholds=[{ color: 'text', value: null }, { color: 'orange', value: 1 }],
         desc='Sessions re-encoding video or audio (remuxes are not counted).'),
  m.stat('Movies', 'max(jellyfin_media_count{type="Movie"})', 12, 1),
  m.stat('Series', 'max(jellyfin_media_count{type="Series"})', 15, 1),
  m.stat('Episodes', 'max(jellyfin_media_count{type="Episode"})', 18, 1),
  m.stat('Pending restart', 'max(jellyfin_system_pending_restart)', 21, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }])
  + grafonnet.panel.stat.standardOptions.withMappings([{ type: 'value', options: { '0': { text: 'no' }, '1': { text: 'yes' } } }]),

  // --- Now playing ----------------------------------------------------------------
  m.row('Now playing', 5),
  m.joinTable('Sessions', 'session_id', [
    { expr: 'max by (%s) (jellyfin_now_playing_state)' % sessionLabels, name: 'State' },
    { expr: 'max by (session_id) (jellyfin_now_playing_progress) / 100', name: 'Progress' },
    { expr: 'max by (session_id) (jellyfin_now_playing_remaining)', name: 'Remaining' },
  ], 0, 6, 24, 7,
    rename={ username: 'User', device: 'Device', type: 'Type', series_title: 'Series', series_season: 'Season', series_episode: 'Ep', title: 'Title', method: 'Method' },
    exclude={ session_id: true, user_id: true },
    order={ username: 0, series_title: 1, series_season: 2, series_episode: 3, title: 4, type: 5, device: 6, method: 7, 'Value #A': 8, 'Value #B': 9, 'Value #C': 10 },
    overrides=[
      m.byName('State', [m.width(90), m.cell('color-text'), m.mappings([
        { type: 'value', options: { '0': { text: 'paused', color: 'orange', index: 0 }, '1': { text: 'playing', color: 'green', index: 1 } } },
      ])]),
      m.byName('Method', [m.width(110), m.cell('color-text'), m.mappings([
        { type: 'value', options: {
          directplay: { text: 'direct play', color: 'green', index: 0 },
          directstream: { text: 'direct stream', color: 'blue', index: 1 },
          transcode: { text: 'transcode', color: 'orange', index: 2 },
        } },
      ])]),
      m.byName('Progress', [m.unit('percentunit'), m.width(180), m.gaugeCell] + m.colorSteps([{ color: 'blue', value: null }])),
      m.byName('Remaining', [m.unit('s'), m.width(100)]),
      m.byName('Season', [m.width(70)]),
      m.byName('Ep', [m.width(60)]),
    ]),
  m.joinTable('Transcodes', 'session_id', [
    { expr: 'max by (session_id, username, title, series_title, container, video_codec, audio_codec, hardware_acceleration) (jellyfin_transcoding_session_info)', name: null },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_height_pixels)', name: 'Height' },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_bitrate_bits_per_second)', name: 'Bitrate' },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_framerate)', name: 'FPS' },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_video_direct)', name: 'Video' },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_audio_direct)', name: 'Audio' },
    { expr: 'max by (session_id) (jellyfin_transcoding_session_completion_percentage) / 100', name: 'Done' },
  ], 0, 13, 16, 7,
    rename={ username: 'User', title: 'Title', series_title: 'Series', container: 'Container', video_codec: 'Video codec', audio_codec: 'Audio codec', hardware_acceleration: 'HW accel' },
    exclude={ session_id: true },
    overrides=[
      m.byName('Bitrate', [m.unit('bps'), m.width(90)]),
      m.byName('FPS', [m.decimals(0), m.width(60)]),
      m.byName('Height', [m.unit('none'), m.width(70)]),
      m.byName('Done', [m.unit('percentunit'), m.width(120), m.gaugeCell] + m.colorSteps([{ color: 'blue', value: null }])),
      m.byName('Video', [m.width(80), m.mappings([{ type: 'value', options: { '0': { text: 'encode', color: 'orange', index: 0 }, '1': { text: 'copy', color: 'green', index: 1 } } }]), m.cell('color-text')]),
      m.byName('Audio', [m.width(80), m.mappings([{ type: 'value', options: { '0': { text: 'encode', color: 'orange', index: 0 }, '1': { text: 'copy', color: 'green', index: 1 } } }]), m.cell('color-text')]),
    ],
    desc='Only sessions that actually re-encode. "copy" = that track is passed through.'),
  m.barGauge('Why transcoding', [q('sort_desc(count by (reason) (jellyfin_transcoding_session_reason))', '{{reason}}')], 16, 13, 8, 7,
             desc='Reasons Jellyfin gives for the active transcodes (codec, container, bitrate or subtitles not supported by the client).'),
  m.ts('Sessions by play method', [q('count by (method) (jellyfin_now_playing_state)', '{{method}}')], 0, 20, 12, 8, 'short', true, 0),
  m.ts('Transcodes', [
    q('max(jellyfin_transcoding_active)', 'transcoding'),
    q('sum(rate(container_cpu_usage_seconds_total{namespace="jellyfin", container="jellyfin"}[$__rate_interval]))', 'Jellyfin CPU (cores)'),
  ], 12, 20, 12, 8, 'short', false, 0),

  // --- Library ------------------------------------------------------------------
  m.row('Libraries and users', 28),
  m.barGauge('Items by type', [q('sort_desc(max by (type) (jellyfin_media_count) > 0)', '{{type}}')], 0, 29, 8, 9),
  m.ts('Library growth', [q('max by (type) (jellyfin_media_count{type=~"Movie|Series|Episode|MusicAlbum|Album"})', '{{type}}')], 8, 29, 8, 9, 'short', legendRight=false),
  m.joinTable('Users', 'user_id', [
    { expr: 'max by (user_id, username, admin) (jellyfin_user_account)', name: null },
    { expr: 'max by (user_id) (label_value(jellyfin_user_account, "last_access")) * 1000', name: 'Last seen' },
    { expr: 'count by (user_id) (jellyfin_user_active)', name: 'Sessions' },
  ], 16, 29, 8, 9,
    rename={ username: 'User', admin: 'Admin' },
    exclude={ user_id: true },
    overrides=[
      m.byName('Admin', [m.width(70), m.mappings([{ type: 'value', options: { '0': { text: '' }, '1': { text: 'admin' } } }])]),
      m.byName('Last seen', [m.unit('dateTimeFromNow')]),
      m.byName('Sessions', [m.width(80)]),
    ],
    sortBy={ displayName: 'Last seen', desc: true }),

  // --- Server ---------------------------------------------------------------------
  m.row('Server', 38),
  m.joinTable('Scheduled tasks', 'task_name', [
    { expr: 'max by (task_name, category, status) (jellyfin_tasks_last_run_status)', name: null },
    { expr: 'max by (task_name) (jellyfin_tasks_last_run_seconds)', name: 'Last run took' },
    { expr: 'max by (task_name, state) (jellyfin_tasks_state)', name: null },
  ], 0, 39, 14, 10,
    rename={ task_name: 'Task', category: 'Category', status: 'Last result', state: 'State' },
    order={ task_name: 0, category: 1, state: 2, status: 3 },
    overrides=[
      m.byName('Last result', [m.width(110), m.cell('color-text'), m.mappings([
        { type: 'value', options: { Completed: { color: 'green', index: 0 }, Failed: { color: 'red', index: 1 }, Aborted: { color: 'orange', index: 2 }, Cancelled: { color: 'text', index: 3 } } },
      ])]),
      m.byName('State', [m.width(90), m.cell('color-text'), m.mappings([
        { type: 'value', options: { Running: { color: 'blue', index: 0 }, Cancelling: { color: 'orange', index: 1 } } },
      ])]),
      m.byName('Last run took', [m.unit('s'), m.width(110)]),
    ],
    sortBy={ displayName: 'Last result', desc: true }),
  m.barGauge('Storage used', [
    q('max by (name) (jellyfin_storage_used_bytes{location!="library"} / (jellyfin_storage_used_bytes{location!="library"} + jellyfin_storage_free_bytes{location!="library"}))', '{{name}}'),
    q('max(jellyfin_storage_used_bytes{location="library"} / (jellyfin_storage_used_bytes{location="library"} + jellyfin_storage_free_bytes{location="library"}))', 'Media libraries'),
  ], 14, 39, 10, 10, 'percentunit',
    thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 0.85 }, { color: 'red', value: 0.95 }], max=1,
    desc='Disk usage behind each Jellyfin location (all libraries share the media disk).'),

  // --- Services -----------------------------------------------------------------
  m.row('Pods and traffic', 49),
]
+ m.serviceStrip('Jellyfin', 'jellyfin', 50)
+ m.serviceStrip('Tracearr', 'tracearr', 56)
+ [
  m.logs('Errors and warnings', m.errorLogs('jellyfin|tracearr'), 0, 62, 24, 10),
])
