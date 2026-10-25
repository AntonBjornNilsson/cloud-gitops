// grafana-folder: Media
// Media stack, "sorting" stage: Sonarr (series), Radarr (movies), Bazarr
// (subtitles) and Recyclarr (TRaSH profile sync).
// Metrics: exportarr (VMPodScrape media-exporters), kube-state-metrics for Recyclarr.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local pct = [{ color: 'red', value: null }, { color: 'orange', value: 0.8 }, { color: 'green', value: 0.95 }];

dashboard.new('Media · Library')
+ dashboard.withUid('media-library')
+ dashboard.withDescription('Sonarr, Radarr, Bazarr and Recyclarr: library size, what is missing, quality, subtitles and health.')
+ dashboard.withTags(['media', 'library', 'sonarr', 'radarr', 'bazarr'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-7d')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withLinks(m.mediaLinks)
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('Series', 'max(sonarr_series_total)', 0, 1),
  m.stat('Episodes on disk', 'max(sonarr_episode_downloaded_total) / max(sonarr_episode_monitored_total)', 3, 1,
         unit='percentunit', thresholds=pct, decimals=1,
         desc='Downloaded episodes as a share of monitored episodes.'),
  m.stat('Missing episodes', 'max(sonarr_episode_missing_total)', 6, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }], graph=true,
         desc='Monitored, aired episodes without a file.'),
  m.stat('Movies', 'max(radarr_movie_total)', 9, 1),
  m.stat('Missing movies', 'max(radarr_movie_missing_total)', 12, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }], graph=true,
         desc='Monitored movies without a file.'),
  m.stat('Library size', 'max(sonarr_series_filesize_bytes) + max(radarr_movie_filesize_total)', 15, 1, unit='bytes', graph=true),
  m.stat('Free space', 'min(sonarr_rootfolder_freespace_bytes or radarr_rootfolder_freespace_bytes)', 18, 1, unit='bytes', graph=true,
         thresholds=[{ color: 'red', value: null }, { color: 'orange', value: 100e9 }, { color: 'green', value: 500e9 }],
         desc='Free space on the media disk (smallest root folder).'),
  m.stat('Missing subtitles', 'max(bazarr_subtitles_missing_total)', 21, 1,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }], graph=true),
  m.arrHealth(['sonarr', 'radarr', 'bazarr'], 0, 5, 24, 6),

  // --- Sonarr -------------------------------------------------------------------
  m.row('Sonarr (series)', 11),
  m.ts('Episodes', [
    q('max(sonarr_episode_downloaded_total)', 'on disk'),
    q('max(sonarr_episode_monitored_total)', 'monitored'),
    q('max(sonarr_episode_total)', 'total'),
  ], 0, 12, 8, 8, 'short', legendRight=false),
  m.ts('Wanted', [
    q('max(sonarr_episode_missing_total)', 'missing'),
    q('max(sonarr_episode_cutoff_unmet_total)', 'cutoff unmet (upgrade wanted)'),
  ], 8, 12, 8, 8, 'short', false, 0, legendRight=false),
  m.barGauge('Episodes by quality', [q('sort_desc(max by (quality) (sonarr_episode_quality_total))', '{{quality}}')], 16, 12, 8, 8),
  m.ts('Activity (history events per hour)', [
    q('sum(rate(sonarr_history_total[$__rate_interval])) * 3600', 'Sonarr'),
    q('sum(rate(radarr_history_total[$__rate_interval])) * 3600', 'Radarr'),
  ], 0, 20, 8, 7, 'short', false, 0, legendRight=false,
    desc='Grabs, imports, upgrades and deletions recorded in each app\'s history.'),
  m.ts('Series', [
    q('max(sonarr_series_total)', 'total'),
    q('max(sonarr_series_monitored_total)', 'monitored'),
    q('max(sonarr_series_downloaded_total)', 'complete'),
  ], 8, 20, 8, 7, 'short', legendRight=false),
  m.ts('Library size', [
    q('max(sonarr_series_filesize_bytes)', 'series'),
    q('max(radarr_movie_filesize_total)', 'movies'),
  ], 16, 20, 8, 7, 'bytes', true, 0, legendRight=false),

  // --- Radarr -------------------------------------------------------------------
  m.row('Radarr (movies)', 27),
  m.ts('Movies', [
    q('max(radarr_movie_downloaded_total)', 'on disk'),
    q('max(radarr_movie_monitored_total)', 'monitored'),
    q('max(radarr_movie_total)', 'total'),
  ], 0, 28, 8, 8, 'short', legendRight=false),
  m.ts('Wanted', [
    q('max(radarr_movie_missing_total)', 'missing'),
    q('max(radarr_movie_cutoff_unmet_total)', 'cutoff unmet (upgrade wanted)'),
  ], 8, 28, 8, 8, 'short', false, 0, legendRight=false),
  m.barGauge('Movies by quality', [q('sort_desc(max by (quality) (radarr_movie_quality_total))', '{{quality}}')], 16, 28, 8, 8),

  // --- Bazarr -------------------------------------------------------------------
  m.row('Bazarr (subtitles)', 36),
  m.ts('Subtitles', [
    q('max(bazarr_subtitles_downloaded_total)', 'downloaded'),
    q('max(bazarr_subtitles_missing_total)', 'missing'),
    q('max(bazarr_movie_subtitles_missing_total)', 'missing (movies)'),
  ], 0, 37, 8, 8, 'short', false, 0, legendRight=false),
  m.pie('By language', [q('max by (language) (bazarr_subtitles_language_total)', '{{language}}')], 8, 37, 5, 8),
  m.pie('By provider', [q('max by (provider) (bazarr_subtitles_provider_total)', '{{provider}}')], 13, 37, 5, 8),
  m.barGauge('Match score', [q('sort_desc(max by (score) (bazarr_subtitles_score_total))', '{{score}}')], 18, 37, 6, 8,
             desc='How well downloaded subtitles matched the release (100% = exact release match).'),

  // --- Recyclarr ----------------------------------------------------------------
  m.row('Recyclarr (TRaSH profile sync)', 45),
  m.stat('Last successful sync', 'time() - max(kube_cronjob_status_last_successful_time{namespace="recyclarr"})', 0, 46, 4, 8, unit='s',
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 2 * 86400 }, { color: 'red', value: 7 * 86400 }]),
  m.stat('Failed jobs', 'sum(kube_job_status_failed{namespace="recyclarr"}) or vector(0)', 4, 46, 4, 8,
         thresholds=[{ color: 'green', value: null }, { color: 'red', value: 1 }],
         desc='Recyclarr jobs still kept by the CronJob history that ended in failure.'),
  m.logs('Last sync output', 'kubernetes.pod_namespace:="recyclarr" | sort by (_time desc) | limit 200', 8, 46, 16, 8),

  // --- Services -----------------------------------------------------------------
  m.row('Pods and traffic', 54),
]
+ m.serviceStrip('Sonarr', 'sonarr', 55)
+ m.serviceStrip('Radarr', 'radarr', 61)
+ m.serviceStrip('Bazarr', 'bazarr', 67)
+ [
  m.logs('Errors and warnings', m.errorLogs('sonarr|radarr|bazarr'), 0, 73, 24, 10),
])
