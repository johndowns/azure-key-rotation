param
(
    [Parameter(Mandatory=$true)]
    [string]
    $ResourceGroupName
)

$ErrorActionPreference = 'Stop'

# Decide whether to use primary or secondary keys for this deployment
$usePrimaryKey = [System.Convert]::ToBoolean((Get-Random 2))
Write-Host "Using $(&{if($usePrimaryKey) { 'primary' } else { 'secondary' }}) keys."

# Deploy ARM template
$armTemplateOutputs = New-AzureRmResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile [System.IO.Path]::Combine($PSScriptRoot, 'template.json') `
    -usePrimaryKey $usePrimaryKey `
    -Mode Complete `
    -Verbose -Force
$storageAccountName = $armTemplateOutputs.Outputs['storageAccountName'].Value
$cosmosDBAccountName = $armTemplateOutputs.Outputs['cosmosDBAccountName'].Value
$serviceBusNamespaceName = $armTemplateOutputs.Outputs['serviceBusNamespaceName'].Value
$testerFunctionUrl = $armTemplateOutputs.Outputs['testerFunctionUrl'].Value

# Wait 20 seconds for the app settings to be updated
Start-Sleep -Seconds 20

# Test to make sure the keys are valid
Write-Host 'Checking keys are valid...'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-RestMethod -Uri $testerFunctionUrl -Method 'Post'

# Rotate storage account keys
$storageKeyNameToRotate = (&{if($usePrimaryKey) { 'key2' } else { 'key1' }})
Write-Host "Rotating key '$storageKeyNameToRotate' in storage account '$storageAccountName'..."
New-AzureRmStorageAccountKey `
    -ResourceGroupName $ResourceGroupName `
    -StorageAccountName $storageAccountName `
    -KeyName $storageKeyNameToRotate

# Rotate Cosmos DB account keys
$cosmosDBKeyNameToRotate = (&{if($usePrimaryKey) { 'secondary' } else { 'primary' }})
Write-Host "Rotating key '$cosmosDBKeyNameToRotate' in Cosmos DB account '$cosmosDBAccountName'..."
Invoke-AzureRmResourceAction `
    -Action 'regenerateKey' `
    -ResourceType 'Microsoft.DocumentDb/databaseAccounts' `
    -ApiVersion '2015-04-08' `
    -ResourceGroupName $ResourceGroupName `
    -Name $cosmosDBAccountName `
    -Parameters @{ 'keyKind' = $cosmosDBKeyNameToRotate } `
    -Force

# Rotate Service Bus keys
$serviceBusKeyNameToRotate = (&{if($usePrimaryKey) { 'SecondaryKey' } else { 'PrimaryKey' }})
$serviceBusPolicyName = 'RootManageSharedAccessKey'
Write-Host "Rotating key '$serviceBusKeyNameToRotate' for policy '$serviceBusPolicyName' in Service Bus namespace '$serviceBusNamespaceName'..."
New-AzureRmServiceBusKey `
    -Name $serviceBusPolicyName `
    -ResourceGroupName $ResourceGroupName `
    -Namespace $serviceBusNamespaceName `
    -RegenerateKey $serviceBusKeyNameToRotate

# Test to make sure we haven't rotated any keys that we're using
Write-Host 'Checking keys are valid...'
Invoke-RestMethod -Uri $testerFunctionUrl -Method 'Post'
