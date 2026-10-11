// Shared pieces for the "Trivy / ..." drilldown dashboards. They read the
// per-finding info metrics of trivy-operator (trivy_vulnerability_id,
// trivy_configaudits_info, trivy_exposedsecrets_info, ...; enabled in
// components/security/trivy-operator) and use MetricsQL (label_value,
// label_map), so they only work against VictoriaMetrics.
//
// The generated manifests carry kustomize.toolkit.fluxcd.io/substitute:
// disabled, so the ${...} forms Grafana needs in data links are safe here.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';

local prometheus = grafonnet.query.prometheus;
local table = grafonnet.panel.table;
local stat = grafonnet.panel.stat;

local ds = { type: 'prometheus', uid: 'VictoriaMetrics' };

{
  ds: ds,

  pos(x, y, w, h):: { gridPos: { x: x, y: y, w: w, h: h } },

  // Reports also exist for ReplicaSets a Deployment has scaled to 0 (old
  // rollouts). $inactive is 0 ("hide") or -1 ("show", matches nothing).
  active(expr)::
    '(%s) unless on (namespace, resource_name) label_replace(kube_replicaset_spec_replicas <= $inactive, "resource_name", "$1", "replicaset", "(.*)")' % expr,

  // Severity label -> number, for "worst severity" columns and sorting.
  severityRank(expr)::
    'label_value(label_map(%s, "severity", "Critical", "4", "High", "3", "Medium", "2", "Low", "1", "Unknown", "0"), "severity")' % expr,

  instant(expr, ref='A')::
    prometheus.new('VictoriaMetrics', expr)
    + prometheus.withInstant(true)
    + prometheus.withFormat('table')
    + prometheus.withRefId(ref),

  // --- Variables --------------------------------------------------------------
  queryVar(name, label, query, regex='', multi=true)::
    {
      type: 'query',
      name: name,
      label: label,
      datasource: ds,
      query: { query: query, refId: 'PrometheusVariableQueryEditor-VariableQuery' },
      definition: query,
      regex: regex,
      refresh: 2,
      sort: 1,
      multi: multi,
      includeAll: true,
      allValue: '.*',
      current: { selected: true, text: ['All'], value: ['$__all'] },
    },

  severityVar:: {
    type: 'custom',
    name: 'severity',
    label: 'Severity',
    query: 'Critical,High,Medium,Low,Unknown',
    multi: true,
    includeAll: true,
    allValue: '.*',
    current: { selected: true, text: ['All'], value: ['$__all'] },
    options: [],
  },

  inactiveVar:: {
    type: 'custom',
    name: 'inactive',
    label: 'Scaled-down ReplicaSets',
    query: 'Hide : 0,Show : -1',
    current: { selected: true, text: 'Hide', value: '0' },
    options: [],
  },

  links:: [
    { type: 'dashboards', tags: ['trivy'], asDropdown: false, includeVars: true, keepTime: true, title: 'Trivy' },
  ],

  // --- Field config -------------------------------------------------------------
  severityTextMappings:: [
    {
      type: 'value',
      options: {
        Critical: { color: 'dark-red', index: 0 },
        High: { color: 'orange', index: 1 },
        Medium: { color: 'yellow', index: 2 },
        Low: { color: 'blue', index: 3 },
        Unknown: { color: 'text', index: 4 },
      },
    },
  ],

  severityRankMappings:: [
    {
      type: 'value',
      options: {
        '4': { text: 'Critical', color: 'dark-red', index: 0 },
        '3': { text: 'High', color: 'orange', index: 1 },
        '2': { text: 'Medium', color: 'yellow', index: 2 },
        '1': { text: 'Low', color: 'blue', index: 3 },
        '0': { text: 'Unknown', color: 'text', index: 4 },
      },
    },
  ],

  override(field, props):: {
    matcher: { id: 'byName', options: field },
    properties: [{ id: k, value: props[k] } for k in std.objectFields(props)],
  },

  colorCell:: { 'custom.cellOptions': { type: 'color-text' } },

  severityColumn(field):: self.override(field, self.colorCell { mappings: $.severityTextMappings }),
  severityRankColumn(field):: self.override(field, self.colorCell { mappings: $.severityRankMappings }),

  // Coloured count column: grey at 0, `color` from 1.
  countColumn(field, color):: self.override(field, {
    'custom.cellOptions': { type: 'color-text' },
    color: { mode: 'thresholds' },
    thresholds: { mode: 'absolute', steps: [{ color: 'text', value: null }, { color: color, value: 1 }] },
  }),

  linkColumn(field, links):: self.override(field, { links: links }),

  link(title, url, blank=false):: { title: title, url: url, targetBlank: blank },

  // Drill into the workload dashboard from any row that has these columns.
  workloadLink:: $.link(
    'Workload drilldown',
    '/d/trivy-workload/?var-namespace=${__data.fields.namespace}&var-workload=${__data.fields.resource_name}&var-container=All&var-severity=All&${inactive:queryparam}&${__url_time_range}'
  ),
  cveLink:: $.link('All affected workloads', '/d/trivy-cve/?var-cve=${__value.raw}&var-package=All&var-severity=All&${inactive:queryparam}&${__url_time_range}'),
  osvLink:: $.link('Advisory (osv.dev)', 'https://osv.dev/vulnerability/${__value.raw}', true),

  // --- Panels -----------------------------------------------------------------
  // Table from one or more instant queries. `columns` maps metric label (or
  // "Value #<ref>") -> header, in display order; everything else is hidden.
  // Multiple queries must return identical label sets: they are merged row-wise.
  tablePanel(title, targets, columns, overrides=[], sortBy=null, description=null)::
    local names = [c[0] for c in columns];
    table.new(title)
    + table.queryOptions.withTargets(targets)
    + table.queryOptions.withTransformations(
      (if std.length(targets) > 1 then [{ id: 'merge', options: {} }] else [])
      + [
        { id: 'filterFieldsByName', options: { include: { names: names } } },
        {
          id: 'organize',
          options: {
            indexByName: { [columns[i][0]]: i for i in std.range(0, std.length(columns) - 1) },
            renameByName: { [c[0]]: c[1] for c in columns if c[0] != c[1] },
          },
        },
      ]
    )
    + table.options.withCellHeight('sm')
    + table.options.footer.withEnablePagination(true)
    + { fieldConfig+: { defaults+: { custom+: { filterable: true } } } }
    + table.standardOptions.withOverrides(overrides)
    + (if sortBy != null then table.options.withSortBy([{ displayName: sortBy, desc: true }]) else {})
    + (if description != null then table.panelOptions.withDescription(description) else {}),

  // One row per scanned container image with CVE counts per severity,
  // fixable packages and exposed secrets. `filter` is a label matcher list.
  imageTable(title, filter, description=null)::
    local L = 'namespace, resource_kind, resource_name, container_name, image_registry, image_repository, image_tag';
    local info = 'trivy_image_info{%s}' % filter;
    local perImage(expr) =
      '(count by (%s) (%s) or 0 * count by (%s) (%s)) * on (%s) group_left (image_os_family, image_os_name) max by (%s, image_os_family, image_os_name) (%s)'
      % [L, $.active(expr), L, $.active(info), L, L, info];
    // Distinct CVEs per image, like the stat panels (one CVE can hit several packages).
    local vuln(sev) = 'count by (%s, vuln_id) (trivy_vulnerability_id{%s, severity="%s"})' % [L, filter, sev];
    $.tablePanel(
      title,
      [
        $.instant(perImage(vuln('Critical')), 'A'),
        $.instant(perImage(vuln('High')), 'B'),
        $.instant(perImage(vuln('Medium')), 'C'),
        $.instant(perImage(vuln('Unknown')), 'D'),
        $.instant(perImage('count by (%s, resource) (trivy_vulnerability_id{%s, severity=~"$severity"})' % [L, filter]), 'E'),
        $.instant(perImage('trivy_exposedsecrets_info{%s}' % filter), 'F'),
      ],
      [
        ['namespace', 'Namespace'],
        ['resource_kind', 'Kind'],
        ['resource_name', 'Workload'],
        ['container_name', 'Container'],
        ['image_repository', 'Repository'],
        ['image_tag', 'Tag'],
        ['image_os_family', 'OS'],
        ['image_os_name', 'OS version'],
        ['Value #A', 'Critical'],
        ['Value #B', 'High'],
        ['Value #C', 'Medium'],
        ['Value #D', 'Unknown'],
        ['Value #E', 'Packages to bump'],
        ['Value #F', 'Secrets'],
      ],
      [
        $.countColumn('Critical', 'dark-red'),
        $.countColumn('High', 'orange'),
        $.countColumn('Medium', 'yellow'),
        $.countColumn('Packages to bump', 'blue'),
        $.countColumn('Secrets', 'purple'),
        $.linkColumn('Workload', [$.workloadLink]),
      ] + [
        $.override(c, { 'custom.width': 90 })
        for c in ['Kind', 'Critical', 'High', 'Medium', 'Unknown', 'Secrets', 'OS', 'OS version']
      ],
      'Critical',
      description,
    ),

  statPanel(title, expr, color, description=null)::
    stat.new(title)
    + stat.queryOptions.withTargets([prometheus.new('VictoriaMetrics', 'sum(' + expr + ') or vector(0)') + prometheus.withInstant(true)])
    + stat.options.withColorMode('background')
    + stat.options.withGraphMode('none')
    + stat.standardOptions.color.withMode('thresholds')
    + stat.standardOptions.thresholds.withSteps([{ color: 'green', value: null }, { color: color, value: 1 }])
    + (if description != null then stat.panelOptions.withDescription(description) else {}),
}
