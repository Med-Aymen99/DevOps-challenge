variable "resource_group_name" {
  description = "The name of the resource group in which to create the AKS cluster."
  default = "devops-project"
}

variable "resource_group_location" {
  description = "The Azure region in which to create the AKS cluster."
  default = "eastus"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS cluster."
  default = "myakscluster"
}

variable "node_count" {
  description = "Number of nodes in the AKS cluster."
  default     = 1
}

variable "vm_size" {
  description = "The size of the VMs in the AKS cluster."
  default     = "Standard_B2s"
}

variable "metric_labels_allowlist" {
  default = null
}

variable "metric_annotations_allowlist" {
  default = null
}

variable "aks_cluster_name" {
  description = "The name of the AKS cluster."
  default = "my-aks-cluster"
}

// ------------- //
// ContainerInsights variables
// ------------- //

variable "subscription_id" {
  type = string
  default = "bcfd15fd-cfda-4dab-b575-b826ed03175d"
}

variable "workspaceName" {
  type = string
  default = "ciworkspace"
}

variable "workspace_region" {
  type = string
  default = "eastus"
}

variable "data_collection_interval" {
  default = "1m"
}

variable "namespace_filtering_mode_for_data_collection" {
  default = "Off"
}

variable "namespaces_for_data_collection" {
  default = ["kube-system", "gatekeeper-system", "azure-arc"]
}

variable "enableContainerLogV2" {
  default = true
}

variable "streams" {
 default = ["Microsoft-ContainerLog", "Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory", "Microsoft-KubeNodeInventory", "Microsoft-KubePVInventory","Microsoft-KubeServices", "Microsoft-KubeMonAgentEvents", "Microsoft-InsightsMetrics", "Microsoft-ContainerInventory",  "Microsoft-ContainerNodeInventory", "Microsoft-Perf"]
}

// ------------- //
// prometheus&Grafana variables
// ------------- //

variable "grafana_name" {
  default = "grafana-prometheus"
}

variable "grafana_sku" {
  default = "Standard"
}

variable "grafana_location" {
  default = "eastus"
}

variable "monitor_workspace_name" {
  default = "amwtest"
}