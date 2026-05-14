param keyVaultId string
param acrId string
param openAiId string
param backendIdentityPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(keyVaultId, '/'))
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: last(split(acrId, '/'))
}

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(openAiId, '/'))
}

// Built-in role definition IDs (verified canonical GUIDs)
// Key Vault Secrets User: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#key-vault-secrets-user
// AcrPull: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#acrpull
// Cognitive Services OpenAI User: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#cognitive-services-openai-user
var kvSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var cognitiveServicesOpenAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

resource keyVaultSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, backendIdentityPrincipalId, 'keyvault-secrets')
  scope: keyVault
  properties: {
    principalId: backendIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: kvSecretsUserRoleId
  }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, backendIdentityPrincipalId, 'acr-pull')
  scope: acr
  properties: {
    principalId: backendIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource openAiUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAi.id, backendIdentityPrincipalId, 'openai-user')
  scope: openAi
  properties: {
    principalId: backendIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAiUserRoleId
  }
}
