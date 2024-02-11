// ------------- //
// AKS resources 
// ------------- //

resource "azurerm_resource_group" "aks_rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
}


resource "azurerm_kubernetes_cluster" "k8s" {
  name                = var.aks_cluster_name
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = var.dns_prefix
  sku_tier   = "Free"

  network_profile {
    network_plugin = "kubenet"
    load_balancer_sku = "standard"
  }

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.vm_size
    type       = "VirtualMachineScaleSets"
    enable_auto_scaling= true
    min_count = 1
    max_count = 3
  }

   monitor_metrics {
    annotations_allowed = var.metric_annotations_allowlist
    labels_allowed      = var.metric_labels_allowlist
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "Production"
  }

  oms_agent {
    log_analytics_workspace_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.aks_cluster_name}/providers/Microsoft.OperationalInsights/workspaces/${var.monitor_workspace_name}"
    msi_auth_for_monitoring_enabled = true
  }

}


// ------------- //
// ContainerInsights resources 
// ------------- //


resource "azurerm_monitor_data_collection_rule" "dcr_1" {
  name                = "MSCI-${var.workspace_region}-${var.aks_cluster_name}"
  resource_group_name = azurerm_resource_group.aks_rg.name
  location            = var.workspace_region

  destinations {
    log_analytics {
      workspace_resource_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.aks_cluster_name}/providers/Microsoft.OperationalInsights/workspaces/${var.workspaceName}"
      name                  = var.workspaceName
    }
  }

  data_flow {
    streams      = var.streams
    destinations = [var.workspaceName]
  }

  data_sources {
    extension {
      streams            = var.streams
      extension_name     = "ContainerInsights"
      extension_json     = jsonencode({
        "dataCollectionSettings" : {
            "interval": var.data_collection_interval,
            "namespaceFilteringMode": var.namespace_filtering_mode_for_data_collection,
            "namespaces": var.namespaces_for_data_collection
            "enableContainerLogV2": var.enableContainerLogV2
        }
      })
      name               = "ContainerInsightsExtension"
    }
  }

  description = "DCR for Azure Monitor Container Insights"
}

resource "azurerm_monitor_data_collection_rule_association" "dcra_1" {
  name                        = "ContainerInsightsExtension"
  target_resource_id          = azurerm_kubernetes_cluster.k8s.id
  data_collection_rule_id     = azurerm_monitor_data_collection_rule.dcr_1.id
  description                 = "Association of container insights data collection rule. Deleting this association will break the data collection for this AKS Cluster."
}


// ------------- //
// prometheus & grafana resources 
// ------------- //

resource "azurerm_monitor_workspace" "amw" {
  name                = var.monitor_workspace_name
  resource_group_name = azurerm_resource_group.aks_rg.name
  
  location            = azurerm_resource_group.aks_rg.location
}

resource "azurerm_monitor_data_collection_endpoint" "dce" {
  name                = "MSProm-${azurerm_resource_group.aks_rg.location}-${var.aks_cluster_name}"
  resource_group_name = azurerm_resource_group.aks_rg.name
  location            = azurerm_resource_group.aks_rg.location
  kind                = "Linux"
}

resource "azurerm_monitor_data_collection_rule" "dcr_2" {
  name                        = "MSProm-${azurerm_resource_group.aks_rg.location}-${var.aks_cluster_name}"
  resource_group_name         = azurerm_resource_group.aks_rg.name
  location                    = azurerm_resource_group.aks_rg.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.dce.id
  kind                        = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.amw.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }


  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }

  description = "DCR for Azure Monitor Metrics Profile (Managed Prometheus)"
  depends_on = [
    azurerm_monitor_data_collection_endpoint.dce
  ]
}

resource "azurerm_monitor_data_collection_rule_association" "dcra_2" {
  name                    = "MSProm-${azurerm_resource_group.aks_rg.location}-${var.aks_cluster_name}"
  target_resource_id      = azurerm_kubernetes_cluster.k8s.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dcr_2.id
  description             = "Association of data collection rule. Deleting this association will break the data collection for this AKS Cluster."
  depends_on = [
    azurerm_monitor_data_collection_rule.dcr_2
  ]
}

resource "azurerm_dashboard_grafana" "grafana" {
  name                = var.grafana_name
  resource_group_name = azurerm_resource_group.aks_rg.name
  location            = var.grafana_location

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.amw.id
  }
}

resource "azurerm_role_assignment" "datareaderrole" {
  scope              = azurerm_monitor_workspace.amw.id
  role_definition_id = "/subscriptions/${split("/", azurerm_monitor_workspace.amw.id)[2]}/providers/Microsoft.Authorization/roleDefinitions/b0d8363b-8ddd-447d-831f-62ca05bff136"
  principal_id       = azurerm_dashboard_grafana.grafana.identity.0.principal_id
}

resource "azurerm_monitor_alert_prometheus_rule_group" "node_recording_rules_rule_group" {
  name                = "NodeRecordingRulesRuleGroup-${var.aks_cluster_name}"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  cluster_name        = var.aks_cluster_name
  description         = "Node Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.amw.id,azurerm_kubernetes_cluster.k8s.id]

  rule {
    enabled    = true
    record     = "instance:node_num_cpu:sum"
    expression = <<EOF
count without (cpu, mode) (  node_cpu_seconds_total{job="node",mode="idle"})
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_cpu_utilisation:rate5m"
    expression = <<EOF
1 - avg without (cpu) (  sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_load1_per_cpu:ratio"
    expression = <<EOF
(  node_load1{job="node"}/  instance:node_num_cpu:sum{job="node"})
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_memory_utilisation:ratio"
    expression = <<EOF
1 - (  (    node_memory_MemAvailable_bytes{job="node"}    or    (      node_memory_Buffers_bytes{job="node"}      +      node_memory_Cached_bytes{job="node"}      +      node_memory_MemFree_bytes{job="node"}      +      node_memory_Slab_bytes{job="node"}    )  )/  node_memory_MemTotal_bytes{job="node"})
EOF
  }
  rule {
    enabled = true

    record     = "instance:node_vmstat_pgmajfault:rate5m"
    expression = <<EOF
rate(node_vmstat_pgmajfault{job="node"}[5m])
EOF
  }
  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_seconds:rate5m"
    expression = <<EOF
rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])
EOF
  }
  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_weighted_seconds:rate5m"
    expression = <<EOF
rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[5m])
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_network_receive_bytes_excluding_lo:rate5m"
    expression = <<EOF
sum without (device) (  rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_network_transmit_bytes_excluding_lo:rate5m"
    expression = <<EOF
sum without (device) (  rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_network_receive_drop_excluding_lo:rate5m"
    expression = <<EOF
sum without (device) (  rate(node_network_receive_drop_total{job="node", device!="lo"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "instance:node_network_transmit_drop_excluding_lo:rate5m"
    expression = <<EOF
sum without (device) (  rate(node_network_transmit_drop_total{job="node", device!="lo"}[5m]))
EOF
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "kubernetes_recording_rules_rule_group" {
  name                = "KubernetesRecordingRulesRuleGroup-${var.aks_cluster_name}"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  cluster_name        = var.aks_cluster_name
  description         = "Kubernetes Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.amw.id,azurerm_kubernetes_cluster.k8s.id]

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate"
    expression = <<EOF
sum by (cluster, namespace, pod, container) (  irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (  1, max by(cluster, namespace, pod, node) (kube_pod_info{node!=""}))
EOF
  }
  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_working_set_bytes"
    expression = <<EOF
container_memory_working_set_bytes{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
EOF
  }
  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_rss"
    expression = <<EOF
container_memory_rss{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
EOF
  }
  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_cache"
    expression = <<EOF
container_memory_cache{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
EOF
  }
  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_swap"
    expression = <<EOF
container_memory_swap{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
EOF
  }
  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_requests"
    expression = <<EOF
kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_requests:sum"
    expression = <<EOF
sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
EOF
  }
  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests"
    expression = <<EOF
kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_requests:sum"
    expression = <<EOF
sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
EOF
  }
  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_limits"
    expression = <<EOF
kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_limits:sum"
    expression = <<EOF
sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
EOF
  }
  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_limits"
    expression = <<EOF
kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) ( (kube_pod_status_phase{phase=~"Pending|Running"} == 1) )
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_limits:sum"
    expression = <<EOF
sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<EOF
max by (cluster, namespace, workload, pod) (  label_replace(    label_replace(      kube_pod_owner{job="kube-state-metrics", owner_kind="ReplicaSet"},      "replicaset", "$1", "owner_name", "(.*)"    ) * on(replicaset, namespace) group_left(owner_name) topk by(replicaset, namespace) (      1, max by (replicaset, namespace, owner_name) (        kube_replicaset_owner{job="kube-state-metrics"}      )    ),    "workload", "$1", "owner_name", "(.*)"  ))
EOF
    labels = {
      workload_type = "deployment"
    }
  }
  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<EOF
max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="DaemonSet"},    "workload", "$1", "owner_name", "(.*)"  ))
EOF
    labels = {
      workload_type = "daemonset"
    }
  }
  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<EOF
max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="StatefulSet"},    "workload", "$1", "owner_name", "(.*)"  ))
EOF
    labels = {
      workload_type = "statefulset"
    }
  }
  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<EOF
max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="Job"},    "workload", "$1", "owner_name", "(.*)"  ))
EOF
    labels = {
      workload_type = "job"
    }
  }
  rule {
    enabled    = true
    record     = ":node_memory_MemAvailable_bytes:sum"
    expression = <<EOF
sum(  node_memory_MemAvailable_bytes{job="node"} or  (    node_memory_Buffers_bytes{job="node"} +    node_memory_Cached_bytes{job="node"} +    node_memory_MemFree_bytes{job="node"} +    node_memory_Slab_bytes{job="node"}  )) by (cluster)
EOF
  }
  rule {
    enabled    = true
    record     = "cluster:node_cpu:ratio_rate5m"
    expression = <<EOF
sum(rate(node_cpu_seconds_total{job="node",mode!="idle",mode!="iowait",mode!="steal"}[5m])) by (cluster) /count(sum(node_cpu_seconds_total{job="node"}) by (cluster, instance, cpu)) by (cluster)
EOF
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "node_and_kubernetes_recording_rules_rule_group_win" {
  name                = "NodeAndKubernetesRecordingRulesRuleGroup-Win-${var.aks_cluster_name}"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  cluster_name        = var.aks_cluster_name
  description         = "Node and Kubernetes Recording Rules Rule Group for Windows Nodes"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.amw.id,azurerm_kubernetes_cluster.k8s.id]

  rule {
    enabled    = true
    record     = "node:windows_node_filesystem_usage:"
    expression = <<EOF
max by (instance,volume)((windows_logical_disk_size_bytes{job="windows-exporter"} - windows_logical_disk_free_bytes{job="windows-exporter"}) / windows_logical_disk_size_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_filesystem_avail:"
    expression = <<EOF
max by (instance, volume) (windows_logical_disk_free_bytes{job="windows-exporter"} / windows_logical_disk_size_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_net_utilisation:sum_irate"
    expression = <<EOF
sum(irate(windows_net_bytes_total{job="windows-exporter"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_net_utilisation:sum_irate"
    expression = <<EOF
sum by (instance) ((irate(windows_net_bytes_total{job="windows-exporter"}[5m])))
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_net_saturation:sum_irate"
    expression = <<EOF
sum(irate(windows_net_packets_received_discarded_total{job="windows-exporter"}[5m])) + sum(irate(windows_net_packets_outbound_discarded_total{job="windows-exporter"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_net_saturation:sum_irate"
    expression = <<EOF
sum by (instance) ((irate(windows_net_packets_received_discarded_total{job="windows-exporter"}[5m]) + irate(windows_net_packets_outbound_discarded_total{job="windows-exporter"}[5m])))
EOF
  }
  rule {
    enabled    = true
    record     = "windows_pod_container_available"
    expression = <<EOF
windows_container_available{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "windows_container_total_runtime"
    expression = <<EOF
windows_container_cpu_usage_seconds_total{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "windows_container_memory_usage"
    expression = <<EOF
windows_container_memory_usage_commit_bytes{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "windows_container_private_working_set_usage"
    expression = <<EOF
windows_container_memory_usage_private_working_set_bytes{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "windows_container_network_received_bytes_total"
    expression = <<EOF
windows_container_network_receive_bytes_total{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "windows_container_network_transmitted_bytes_total"
    expression = <<EOF
windows_container_network_transmit_bytes_total{job="windows-exporter", container_id != ""} * on(container_id) group_left(container, pod, namespace) max(kube_pod_container_info{job="kube-state-metrics", container_id != ""}) by(container, container_id, pod, namespace)
EOF
  }
  rule {
    enabled    = true
    record     = "kube_pod_windows_container_resource_memory_request"
    expression = <<EOF
max by (namespace, pod, container) (kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}) * on(container,pod,namespace) (windows_pod_container_available)
EOF
  }
  rule {
    enabled    = true
    record     = "kube_pod_windows_container_resource_memory_limit"
    expression = <<EOF
kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"} * on(container,pod,namespace) (windows_pod_container_available)
EOF
  }
  rule {
    enabled    = true
    record     = "kube_pod_windows_container_resource_cpu_cores_request"
    expression = <<EOF
max by (namespace, pod, container) ( kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}) * on(container,pod,namespace) (windows_pod_container_available)
EOF
  }
  rule {
    enabled    = true
    record     = "kube_pod_windows_container_resource_cpu_cores_limit"
    expression = <<EOF
kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"} * on(container,pod,namespace) (windows_pod_container_available)
EOF
  }
  rule {
    enabled    = true
    record     = "namespace_pod_container:windows_container_cpu_usage_seconds_total:sum_rate"
    expression = <<EOF
sum by (namespace, pod, container) (rate(windows_container_total_runtime{}[5m]))
EOF
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "node_recording_rules_rule_group_win" {
  name                = "NodeRecordingRulesRuleGroup-Win-${var.aks_cluster_name}"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  cluster_name        = var.aks_cluster_name
  description         = "Node and Kubernetes Recording Rules Rule Group for Windows Nodes"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.amw.id,azurerm_kubernetes_cluster.k8s.id]

  rule {
    enabled    = true
    record     = "node:windows_node:sum"
    expression = <<EOF
count (windows_system_system_up_time{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_num_cpu:sum"
    expression = <<EOF
count by (instance) (sum by (instance, core) (windows_cpu_time_total{job="windows-exporter"}))
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_cpu_utilisation:avg5m"
    expression = <<EOF
1 - avg(rate(windows_cpu_time_total{job="windows-exporter",mode="idle"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_cpu_utilisation:avg5m"
    expression = <<EOF
1 - avg by (instance) (rate(windows_cpu_time_total{job="windows-exporter",mode="idle"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_memory_utilisation:"
    expression = <<EOF
1 -sum(windows_memory_available_bytes{job="windows-exporter"})/sum(windows_os_visible_memory_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_memory_MemFreeCached_bytes:sum"
    expression = <<EOF
sum(windows_memory_available_bytes{job="windows-exporter"} + windows_memory_cache_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_totalCached_bytes:sum"
    expression = <<EOF
(windows_memory_cache_bytes{job="windows-exporter"} + windows_memory_modified_page_list_bytes{job="windows-exporter"} + windows_memory_standby_cache_core_bytes{job="windows-exporter"} + windows_memory_standby_cache_normal_priority_bytes{job="windows-exporter"} + windows_memory_standby_cache_reserve_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_memory_MemTotal_bytes:sum"
    expression = <<EOF
sum(windows_os_visible_memory_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_bytes_available:sum"
    expression = <<EOF
sum by (instance) ((windows_memory_available_bytes{job="windows-exporter"}))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_bytes_total:sum"
    expression = <<EOF
sum by (instance) (windows_os_visible_memory_bytes{job="windows-exporter"})
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_utilisation:ratio"
    expression = <<EOF
(node:windows_node_memory_bytes_total:sum - node:windows_node_memory_bytes_available:sum) / scalar(sum(node:windows_node_memory_bytes_total:sum))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_utilisation:"
    expression = <<EOF
1 - (node:windows_node_memory_bytes_available:sum / node:windows_node_memory_bytes_total:sum)
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_memory_swap_io_pages:irate"
    expression = <<EOF
irate(windows_memory_swap_page_operations_total{job="windows-exporter"}[5m])
EOF
  }
  rule {
    enabled    = true
    record     = ":windows_node_disk_utilisation:avg_irate"
    expression = <<EOF
avg(irate(windows_logical_disk_read_seconds_total{job="windows-exporter"}[5m]) + irate(windows_logical_disk_write_seconds_total{job="windows-exporter"}[5m]))
EOF
  }
  rule {
    enabled    = true
    record     = "node:windows_node_disk_utilisation:avg_irate"
    expression = <<EOF
avg by (instance) ((irate(windows_logical_disk_read_seconds_total{job="windows-exporter"}[5m]) + irate(windows_logical_disk_write_seconds_total{job="windows-exporter"}[5m])))
EOF
  }
}