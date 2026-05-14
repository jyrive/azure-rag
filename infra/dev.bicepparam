using './main.bicep'

param environmentName = 'dev'
param location = 'westeurope'
param containerAppsLocation = 'northeurope'
// Overridden by the workflow with the freshly built ACR image tag.
param backendImage = 'mcr.microsoft.com/k8se/quickstart:latest'
