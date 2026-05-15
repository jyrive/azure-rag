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

@description('Database name for the RAG Mongo API data store.')
param cosmosDatabaseName string = 'rag'

@description('Collection name for indexed RAG documents.')
param cosmosCollectionName string = 'documents'

@description('Cosmos DB account kind. GlobalDocumentDB supports Mongo API.')
@allowed([
  'GlobalDocumentDB'
])
param cosmosDatabaseAccountKind string = 'GlobalDocumentDB'

var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
var containerEnvName = 'aca-${environmentName}-${shortSuffix}-${toLower(containerAppsLocation)}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')
var cosmosAccountName = toLower('cos${environmentName}${shortSuffix}')
var keyVaultName = toLower('kv-${environmentName}-${shortSuffix}')

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

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: cosmosAccountName
  location: containerAppsLocation
  kind: cosmosDatabaseAccountKind
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: containerAppsLocation
        failoverPriority: 0
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    capabilities: [
      {
        name: 'EnableMongo'
      }
    ]
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/mongodbDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: cosmosDatabaseName
  properties: {
    resource: {
      id: cosmosDatabaseName
    }
    options: {}
  }
}

resource cosmosCollection 'Microsoft.DocumentDB/databaseAccounts/mongodbDatabases/collections@2023-11-15' = {
  parent: cosmosDatabase
  name: cosmosCollectionName
  properties: {
    resource: {
      id: cosmosCollectionName
      shardKey: {
        _id: 'Hash'
      }
    }
    options: {
      throughput: 400
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: containerAppsLocation
  properties: {
    tenantId: tenant().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enablePurgeProtection: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
  }
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
output cosmosAccountNameOut string = cosmosAccount.name
output cosmosDatabaseNameOut string = cosmosDatabase.name
output cosmosCollectionNameOut string = cosmosCollection.name
output keyVaultNameOut string = keyVault.name
