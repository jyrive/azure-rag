targetScope = 'resourceGroup'

@description('Logical environment name, e.g. dev or prod.')
param environmentName string

@description('Region for the Static Web App. SWA is only available in a fixed set of regions; westeurope works.')
param location string = 'westeurope'

@description('Region for the Container Apps managed environment. westeurope has been capacity-constrained for AKS-backed managed envs; northeurope is reliable.')
param containerAppsLocation string = 'northeurope'

@description('SKU for the Static Web App. Free is fine for dev.')
param frontendSkuName string = 'Free'

@description('Fully-qualified container image for the backend. Defaults to a public placeholder so the template is usable before ACR exists; the workflow overrides this with our ACR-built image.')
param backendImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Resource ID of the user-assigned managed identity used to pull from ACR. Empty means no registry auth (placeholder image only).')
param userAssignedIdentityId string = ''

@description('ACR login server (e.g. crdevgv7ax7.azurecr.io). Empty means no registry auth is configured on the container app.')
param acrLoginServer string = ''

@description('Container port the backend listens on. FastAPI/uvicorn defaults to 8000; the public placeholder serves 80.')
param backendTargetPort int = 8000

var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
var containerEnvName = 'aca-${environmentName}-${shortSuffix}-${toLower(containerAppsLocation)}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')

var useUami = !empty(userAssignedIdentityId) && !empty(acrLoginServer)

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvName
  location: containerAppsLocation
  properties: {}
}

resource backendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: containerAppsLocation
  identity: useUami ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  } : {
    type: 'None'
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
      registries: useUami ? [
        {
          server: acrLoginServer
          identity: userAssignedIdentityId
        }
      ] : []
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
