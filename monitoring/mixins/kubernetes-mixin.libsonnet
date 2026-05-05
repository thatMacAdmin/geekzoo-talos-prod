local kubernetes = import 'kubernetes-mixin/mixin.libsonnet';

kubernetes {
  _config+:: {
    clusterLabel: 'cluster',
    clusterLabelValue: 'geekzoo-prod',
    datasourceName: 'VictoriaMetrics',
  },
}
