param environmentName string
param location string
param openAiLocation string
param shortSuffix string
param keyVaultName string
param acrName string
param cosmosAccountName string
param openAiName string
param openAiCustomSubdomain string
param eventGridTopicName string
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

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAiName
  location: openAiLocation
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: openAiCustomSubdomain
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: 'gpt-4.1-mini'
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1-mini'
      version: '2025-04-14'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: 'text-embedding-3-small'
  dependsOn: [
    chatDeployment
  ]
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource eventGridTopic 'Microsoft.EventGrid/topics@2022-06-15' = {
  name: eventGridTopicName
  location: location
  properties: {
    publicNetworkAccess: 'Enabled'
    inputSchema: 'EventGridSchema'
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
var eventGridTopicKey = eventGridTopic.listSharedAccessKeys().key1

resource cosmosConnSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'cosmos-connection-string'
  properties: {
    value: cosmosConnString
  }
}

resource openAiEndpointSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'openai-endpoint'
  properties: {
    value: openAi.properties.endpoint
  }
}

resource eventGridEndpointSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'eventgrid-topic-endpoint'
  properties: {
    value: eventGridTopic.properties.endpoint
  }
}

resource eventGridKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'eventgrid-topic-key'
  properties: {
    value: eventGridTopicKey
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
output openAiId string = openAi.id
output openAiNameOut string = openAi.name
output openAiEndpoint string = openAi.properties.endpoint
output chatDeploymentName string = chatDeployment.name
output embeddingDeploymentName string = embeddingDeployment.name
output eventGridTopicId string = eventGridTopic.id
output eventGridTopicNameOut string = eventGridTopic.name
output eventGridTopicEndpoint string = eventGridTopic.properties.endpoint
output containerEnvId string = containerEnv.id
output cosmosSecretName string = cosmosConnSecret.name
output openAiEndpointSecretName string = openAiEndpointSecret.name
output eventGridEndpointSecretName string = eventGridEndpointSecret.name
output eventGridKeySecretName string = eventGridKeySecret.name
