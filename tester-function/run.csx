#r "Microsoft.WindowsAzure.Storage"

using System;
using System.Configuration;
using System.Net;
using Microsoft.Azure.Documents;
using Microsoft.Azure.Documents.Client;
using Microsoft.ServiceBus;
using Microsoft.WindowsAzure.Storage;

public static async Task<HttpResponseMessage> Run(HttpRequestMessage req, TraceWriter log)
{
    // Test connectivity to Azure Storage
    try
    {
        var storageAccount = CloudStorageAccount.Parse(ConfigurationManager.AppSettings["StorageAccountConnectionString"]);
        var storageClient = storageAccount.CreateCloudBlobClient();
        var storageContainer = storageClient.GetContainerReference("mycontainer");
        await storageContainer.ExistsAsync();
    }
    catch (StorageException ex) when (ex.RequestInformation.HttpStatusCode == 403)
    {
        return req.CreateResponse(HttpStatusCode.InternalServerError, "The storage account key is not valid.");
    }

    // Test connectivity to Cosmos DB
    try
    {
        var cosmosDBClient = new DocumentClient(
            new Uri(ConfigurationManager.AppSettings["CosmosDBAccountEndpoint"]), 
            ConfigurationManager.AppSettings["CosmosDBAccountKey"]);
        await cosmosDBClient.GetDatabaseAccountAsync();
    }
    catch (DocumentClientException ex) when (ex.StatusCode == HttpStatusCode.Unauthorized)
    {
        return req.CreateResponse(HttpStatusCode.InternalServerError, "The Cosmos DB account key is not valid.");
    }

    // Test connectivity to Service Bus
    try
    {
        var serviceBusNamespaceManager = NamespaceManager.CreateFromConnectionString(ConfigurationManager.AppSettings["ServiceBusNamespaceConnectionString"]);
        await serviceBusNamespaceManager.GetQueuesAsync();
    }
    catch (UnauthorizedAccessException ex)
    {
        return req.CreateResponse(HttpStatusCode.InternalServerError, "The Service Bus namespace key is not valid.");
    }

    // If we got this far then everything is fine
    return req.CreateResponse(HttpStatusCode.OK);
}
