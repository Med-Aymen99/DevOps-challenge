terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.90.0"
    }

    azapi = {
      source  = "azure/azapi"
      version = "=0.1.0"
    }
  }
}

provider "azapi" {
  default_location = "eastus"
}

provider "azurerm" {
  features {}

  subscription_id = "bcfd15fd-cfda-4dab-b575-b826ed03175d"
  tenant_id       = "dbd6664d-4eb9-46eb-99d8-5c43ba153c61"
  client_id       = "71b36623-8cd1-426e-8d71-b6979edd21d8"
  client_secret   = "RpE8Q~N5Ml6til9~2I5KFFcZ~16iKcUWlETqNc_k"

}
