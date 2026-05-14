targetScope = 'resourceGroup'

@description('Logical environment name, e.g. dev or prod.')
param environmentName string

@description('Region for the Static Web App. SWA is only available in a fixed set of regions; westeurope works.')
param location string = 'westeurope'

@description('Region for the Container Apps managed environment. westeurope has been capacity-constrained for AKS-backed managed envs; northeurope is reliable.')
param containerAppsLocation string = 'northeurope'

@description('SKU for the Static Web App. Free is fine for dev.')
param frontendSkuName string = 'Free'

@description('Public container image used as the backend placeholder until we wire up our own ACR + image.')
param backendImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// Stable suffix: NOT location-dependent, so switching regions never invents new
// resource names and orphans existing ones.
var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
// Region is baked into the env name only, so we can recreate it in a new region
// without colliding with a CreateFailed instance left over in an old region.
var containerEnvName = 'aca-${environmentName}-${shortSuffix}-${toLower(containerAppsLocation)}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvName
  location: containerAppsLocation
  properties: {}
}

resource backendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: containerAppsLocation
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: backendImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

resource staticSite 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticSiteName
  location: location
  sku: {
    name: frontendSkuName
    tier: frontendSkuName
  }
  properties: {}
}

output backendAppFqdn string = backendApp.properties.configuration.ingress.fqdn
output backendAppName string = backendApp.name
output staticSiteNameOut string = staticSite.name
output staticSiteDefaultHostname string = staticSite.properties.defaultHostname
