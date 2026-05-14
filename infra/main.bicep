targetScope = 'resourceGroup'

param environmentName string
param location string = resourceGroup().location
param openAiLocation string = 'eastus'
param backendImageName string = 'azure-rag-backend'
param backendImageTag string = 'latest'
param frontendSkuName string = 'Standard'
param enableSwaLinkedBackend bool = true

var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName, location), 0, 6)
var keyVaultName = toLower('kv-${environmentName}-${shortSuffix}')
var acrName = toLower('acr${environmentName}${shortSuffix}')
var cosmosAccountName = toLower('cosmos${environmentName}${shortSuffix}')
var containerEnvName = 'aca-${environmentName}-${shortSuffix}'
var backendAppName = 'api-${environmentName}-${shortSuffix}'
var workerAppName = 'worker-${environmentName}-${shortSuffix}'
var staticSiteName = toLower('swa${environmentName}${shortSuffix}')
var openAiName = toLower('aoai-${environmentName}-${shortSuffix}')
var openAiCustomSubdomain = toLower('aoai-${environmentName}-${shortSuffix}')
var eventGridTopicName = 'evt-${environmentName}-${shortSuffix}'

module core './modules/core.bicep' = {
  name: 'core'
  params: {
    environmentName: environmentName
    location: location
    openAiLocation: openAiLocation
    shortSuffix: shortSuffix
    keyVaultName: keyVaultName
    acrName: acrName
    cosmosAccountName: cosmosAccountName
    openAiName: openAiName
    openAiCustomSubdomain: openAiCustomSubdomain
    eventGridTopicName: eventGridTopicName
    containerEnvName: containerEnvName
  }
}

module apps './modules/apps.bicep' = {
  name: 'apps'
  params: {
    environmentName: environmentName
    location: location
    backendAppName: backendAppName
    workerAppName: workerAppName
    managedEnvironmentId: core.outputs.containerEnvId
    acrLoginServer: core.outputs.acrLoginServer
    backendImageName: backendImageName
    backendImageTag: backendImageTag
    backendIdentityId: core.outputs.backendIdentityId
    backendIdentityClientId: core.outputs.backendIdentityClientId
    keyVaultUrl: core.outputs.keyVaultUrl
    cosmosSecretName: core.outputs.cosmosSecretName
    openAiEndpointSecretName: core.outputs.openAiEndpointSecretName
    eventGridEndpointSecretName: core.outputs.eventGridEndpointSecretName
    eventGridKeySecretName: core.outputs.eventGridKeySecretName
    chatDeploymentName: core.outputs.chatDeploymentName
    embeddingDeploymentName: core.outputs.embeddingDeploymentName
  }
}

module eventing './modules/eventing.bicep' = {
  name: 'eventing'
  params: {
    eventGridTopicName: core.outputs.eventGridTopicNameOut
    workerWebhookUrl: 'https://${apps.outputs.workerAppFqdn}/api/worker/eventgrid'
  }
}

module access './modules/access.bicep' = {
  name: 'access'
  params: {
    keyVaultId: core.outputs.keyVaultId
    acrId: core.outputs.acrId
    openAiId: core.outputs.openAiId
    backendIdentityPrincipalId: core.outputs.backendIdentityPrincipalId
  }
}

module frontend './modules/frontend.bicep' = {
  name: 'frontend'
  params: {
    staticSiteName: staticSiteName
    location: location
    frontendSkuName: frontendSkuName
    backendResourceId: apps.outputs.backendAppId
    enableLinkedBackend: enableSwaLinkedBackend
  }
}

output environmentNameOut string = environmentName
output keyVaultUrl string = core.outputs.keyVaultUrl
output acrLoginServer string = core.outputs.acrLoginServer
output acrName string = core.outputs.acrNameOut
output cosmosAccountName string = core.outputs.cosmosAccountNameOut
output openAiName string = core.outputs.openAiNameOut
output openAiEndpoint string = core.outputs.openAiEndpoint
output eventGridTopicName string = core.outputs.eventGridTopicNameOut
output eventGridTopicEndpoint string = core.outputs.eventGridTopicEndpoint
output backendAppFqdn string = apps.outputs.backendAppFqdn
output backendAppName string = apps.outputs.backendAppNameOut
output workerAppFqdn string = apps.outputs.workerAppFqdn
output workerAppName string = apps.outputs.workerAppNameOut
output eventSubscriptionName string = eventing.outputs.eventSubscriptionName
output staticSiteNameOut string = frontend.outputs.staticSiteNameOut
output staticSiteDefaultHostname string = frontend.outputs.staticSiteDefaultHostname
output staticSiteLinkedBackendName string = frontend.outputs.linkedBackendName
