targetScope = 'resourceGroup'

param environmentName string
param location string = resourceGroup().location
param openAiLocation string = 'eastus'
param backendImageName string = 'azure-rag-backend'
param backendImageTag string = 'latest'
param frontendSkuName string = 'Free'

// Stable suffix: does NOT include location, so changing regions does not invent
// new resource names that orphan/soft-delete the old ones.
var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
var keyVaultName = toLower('kv-${environmentName}-${shortSuffix}')
var acrName = toLower('acr${environmentName}${shortSuffix}')
var cosmosAccountName = toLower('cosmos${environmentName}${shortSuffix}')
var containerEnvName = 'aca-${environmentName}-${shortSuffix}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')
var openAiName = toLower('aoai-${environmentName}-${shortSuffix}')

module core './modules/core.bicep' = {
  name: 'core'
  params: {
    location: location
    openAiLocation: openAiLocation
    environmentName: environmentName
    shortSuffix: shortSuffix
    keyVaultName: keyVaultName
    acrName: acrName
    cosmosAccountName: cosmosAccountName
    openAiName: openAiName
    containerEnvName: containerEnvName
  }
}

// Role assignments must exist BEFORE the container app tries to pull from ACR
// and read Key Vault secrets, otherwise the first revision fails to start.
module access './modules/access.bicep' = {
  name: 'access'
  params: {
    keyVaultId: core.outputs.keyVaultId
    acrId: core.outputs.acrId
    openAiId: core.outputs.openAiId
    backendIdentityPrincipalId: core.outputs.backendIdentityPrincipalId
  }
}

module apps './modules/apps.bicep' = {
  name: 'apps'
  dependsOn: [
    access
  ]
  params: {
    environmentName: environmentName
    location: location
    backendAppName: backendAppName
    managedEnvironmentId: core.outputs.containerEnvId
    acrLoginServer: core.outputs.acrLoginServer
    backendImageName: backendImageName
    backendImageTag: backendImageTag
    backendIdentityId: core.outputs.backendIdentityId
    backendIdentityClientId: core.outputs.backendIdentityClientId
    keyVaultUrl: core.outputs.keyVaultUrl
    cosmosSecretName: core.outputs.cosmosSecretName
    openAiEndpointSecretName: core.outputs.openAiEndpointSecretName
    chatDeploymentName: core.outputs.chatDeploymentName
    embeddingDeploymentName: core.outputs.embeddingDeploymentName
  }
}

module frontend './modules/frontend.bicep' = {
  name: 'frontend'
  params: {
    staticSiteName: staticSiteName
    location: location
    frontendSkuName: frontendSkuName
  }
}

output environmentNameOut string = environmentName
output keyVaultUrl string = core.outputs.keyVaultUrl
output acrLoginServer string = core.outputs.acrLoginServer
output acrName string = core.outputs.acrNameOut
output cosmosAccountName string = core.outputs.cosmosAccountNameOut
output openAiName string = core.outputs.openAiNameOut
output openAiEndpoint string = core.outputs.openAiEndpoint
output backendAppFqdn string = apps.outputs.backendAppFqdn
output backendAppName string = apps.outputs.backendAppNameOut
output staticSiteNameOut string = frontend.outputs.staticSiteNameOut
output staticSiteDefaultHostname string = frontend.outputs.staticSiteDefaultHostname
