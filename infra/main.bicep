targetScope = 'resourceGroup'

@description('Logical environment name, e.g. dev or prod.')
param environmentName string

@description('Region for the Static Web App. SWA is only available in a fixed set of regions; westeurope works.')
param location string = 'westeurope'

@description('Region for the Container Apps managed environment. westeurope has been capacity-constrained for AKS-backed managed envs; northeurope is reliable.')
param containerAppsLocation string = 'northeurope'

@description('SKU for the Static Web App. Free is fine for dev.')
param frontendSkuName string = 'Free'

@description('Fully-qualified container image for the backend. The workflow passes the ACR-built tag here.')
param backendImage string

@description('Container port the backend listens on. FastAPI/uvicorn defaults to 8000; the public placeholder serves 80.')
param backendTargetPort int = 8000

var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
var containerEnvName = 'aca-${environmentName}-${shortSuffix}-${toLower(containerAppsLocation)}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')

// Registry + identity are provisioned separately by registry.bicep using the same
// suffix scheme, so we can resolve them here without the workflow plumbing IDs through.
var acrName = toLower('cr${environmentName}${shortSuffix}')
var uamiName = 'id-${environmentName}-${shortSuffix}'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: uamiName
}

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvName
  location: containerAppsLocation
  properties: {}
}

resource backendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: containerAppsLocation
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: backendTargetPort
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uami.id
        }
      ]
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
