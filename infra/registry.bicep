targetScope = 'resourceGroup'

@description('Logical environment name, e.g. dev or prod.')
param environmentName string

@description('Region for the registry and identity. Anything close to the Container Apps region is fine; ACR is global anyway.')
param location string = 'northeurope'

// Same suffix scheme as main.bicep so registry/identity names stay stable
// regardless of which region the rest of the stack lives in.
var shortSuffix = substring(uniqueString(resourceGroup().id, environmentName), 0, 6)
var acrName = toLower('cr${environmentName}${shortSuffix}')
var uamiName = 'id-${environmentName}-${shortSuffix}'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// AcrPull role definition id — well-known constant.
var acrPullRoleDefinitionId = '7f951dda-4ed3-11e8-bbf0-0a580a020228'

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, uami.id, acrPullRoleDefinitionId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output uamiId string = uami.id
output uamiName string = uami.name
output uamiPrincipalId string = uami.properties.principalId
output uamiClientId string = uami.properties.clientId
