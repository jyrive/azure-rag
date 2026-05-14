param staticSiteName string
param location string
param frontendSkuName string

resource staticSite 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticSiteName
  location: location
  sku: {
    name: frontendSkuName
    tier: frontendSkuName
  }
  properties: {}
}

output staticSiteNameOut string = staticSite.name
output staticSiteDefaultHostname string = staticSite.properties.defaultHostname
