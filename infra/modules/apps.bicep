param environmentName string
param location string
param backendAppName string
param workerAppName string
param managedEnvironmentId string
param acrLoginServer string
param backendImageName string
param backendImageTag string
param backendIdentityId string
param backendIdentityClientId string
param keyVaultUrl string
param cosmosSecretName string
param openAiEndpointSecretName string
param eventGridEndpointSecretName string
param eventGridKeySecretName string
param chatDeploymentName string
param embeddingDeploymentName string

resource backendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${backendIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acrLoginServer
          identity: backendIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: '${acrLoginServer}/${backendImageName}:${backendImageTag}'
          env: [
            {
              name: 'APP_ROLE'
              value: 'api'
            }
            {
              name: 'AZURE_ENVIRONMENT'
              value: environmentName
            }
            {
              name: 'KEY_VAULT_URL'
              value: keyVaultUrl
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: backendIdentityClientId
            }
            {
              name: 'KEYVAULT_COSMOS_SECRET_NAME'
              value: cosmosSecretName
            }
            {
              name: 'KEYVAULT_OPENAI_ENDPOINT_SECRET_NAME'
              value: openAiEndpointSecretName
            }
            {
              name: 'KEYVAULT_EVENTGRID_ENDPOINT_SECRET_NAME'
              value: eventGridEndpointSecretName
            }
            {
              name: 'KEYVAULT_EVENTGRID_KEY_SECRET_NAME'
              value: eventGridKeySecretName
            }
            {
              name: 'AZURE_OPENAI_CHAT_DEPLOYMENT'
              value: chatDeploymentName
            }
            {
              name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT'
              value: embeddingDeploymentName
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
}

resource workerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: workerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${backendIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acrLoginServer
          identity: backendIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: '${acrLoginServer}/${backendImageName}:${backendImageTag}'
          env: [
            {
              name: 'APP_ROLE'
              value: 'worker'
            }
            {
              name: 'AZURE_ENVIRONMENT'
              value: environmentName
            }
            {
              name: 'KEY_VAULT_URL'
              value: keyVaultUrl
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: backendIdentityClientId
            }
            {
              name: 'KEYVAULT_COSMOS_SECRET_NAME'
              value: cosmosSecretName
            }
            {
              name: 'KEYVAULT_OPENAI_ENDPOINT_SECRET_NAME'
              value: openAiEndpointSecretName
            }
            {
              name: 'KEYVAULT_EVENTGRID_ENDPOINT_SECRET_NAME'
              value: eventGridEndpointSecretName
            }
            {
              name: 'KEYVAULT_EVENTGRID_KEY_SECRET_NAME'
              value: eventGridKeySecretName
            }
            {
              name: 'AZURE_OPENAI_CHAT_DEPLOYMENT'
              value: chatDeploymentName
            }
            {
              name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT'
              value: embeddingDeploymentName
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
      }
    }
  }
}

output backendAppNameOut string = backendApp.name
output backendAppFqdn string = backendApp.properties.configuration.ingress.fqdn
output backendAppId string = backendApp.id
output workerAppNameOut string = workerApp.name
output workerAppFqdn string = workerApp.properties.configuration.ingress.fqdn
