param eventGridTopicName string
@secure()
param workerWebhookUrl string

resource eventGridTopic 'Microsoft.EventGrid/topics@2022-06-15' existing = {
  name: eventGridTopicName
}

resource eventSubscription 'Microsoft.EventGrid/topics/eventSubscriptions@2022-06-15' = {
  parent: eventGridTopic
  name: 'worker-sub'
  properties: {
    destination: {
      endpointType: 'WebHook'
      properties: {
        endpointUrl: workerWebhookUrl
      }
    }
    filter: {
      isSubjectCaseSensitive: false
      includedEventTypes: [
        'rag.document.requested'
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output eventSubscriptionName string = eventSubscription.name
