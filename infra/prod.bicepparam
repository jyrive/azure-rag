using './main.bicep'

param environmentName = 'prod'
param location = 'westeurope'
param containerAppsLocation = 'northeurope'
// Overridden by the workflow with the freshly built ACR image tag.
param backendImage = 'mcr.microsoft.com/k8se/quickstart:latest'
