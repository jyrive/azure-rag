param staticSiteName string
param location string
param frontendSkuName string
param backendResourceId string
param enableLinkedBackend bool = true

resource staticSite 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticSiteName
  location: location
  sku: {
    name: frontendSkuName
    tier: frontendSkuName
  }
  properties: {}
}

resource linkedBackend 'Microsoft.Web/staticSites/linkedBackends@2023-12-01' = if (enableLinkedBackend && backendResourceId != '') {
  parent: staticSite
  name: 'backend'
  properties: {
    backendResourceId: backendResourceId
    region: location
  }
}

output staticSiteNameOut string = staticSite.name
output staticSiteDefaultHostname string = staticSite.properties.defaultHostname
output linkedBackendName string = enableLinkedBackend && backendResourceId != '' ? linkedBackend.name : ''
