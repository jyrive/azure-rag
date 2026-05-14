param environmentName string
param location string
param shortSuffix string
param keyVaultName string
param acrName string
param cosmosAccountName string
param containerEnvName string

resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${environmentName}-${shortSuffix}'
  location: location
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-08-15' = {
  name: cosmosAccountName
  location: location
  kind: 'MongoDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
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
    isVirtualNetworkFilterEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvName
  location: location
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

var cosmosPrimaryKey = cosmosAccount.listKeys().primaryMasterKey
var cosmosConnString = 'mongodb://${cosmosAccount.name}:${cosmosPrimaryKey}@${cosmosAccount.name}.mongo.cosmos.azure.com:10255/?ssl=true&retrywrites=false&maxIdleTimeMS=120000&appName=@${cosmosAccount.name}@'
resource cosmosConnSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'cosmos-connection-string'
  properties: {
    value: cosmosConnString
  }
}

output backendIdentityId string = backendIdentity.id
output backendIdentityClientId string = backendIdentity.properties.clientId
output backendIdentityPrincipalId string = backendIdentity.properties.principalId
output keyVaultId string = keyVault.id
output keyVaultUrl string = keyVault.properties.vaultUri
output acrId string = acr.id
output acrLoginServer string = acr.properties.loginServer
output acrNameOut string = acr.name
output cosmosAccountNameOut string = cosmosAccount.name
output containerEnvId string = containerEnv.id
output cosmosSecretName string = cosmosConnSecret.name
