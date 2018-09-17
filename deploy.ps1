param
(
    [Parameter(Mandatory=$true)]
    [string]
    $ResourceGroupName
)

$ErrorActionPreference = 'Stop'

# Create some functions that we'll use to manage resource group tags to tell us which keys we're currently using
function GetUsePrimaryKeyTag($ResourceGroupName)
{
    $resourceGroupTags = (Get-AzureRmResourceGroup -Name $ResourceGroupName).Tags
    if ($null -ne $resourceGroupTags -and $resourceGroupTags['CurrentKeys'] -eq 'Primary')
    {
        return $false
    }
    else
    {
        return $true
    }
}

function UpdateUsePrimaryKeyTag($ResourceGroupName, $UsePrimaryKey)
{
    $tagValue = (&{if($usePrimaryKey) { 'Primary' } else { 'Secondary' }})
    $group = Get-AzureRmResourceGroup $ResourceGroupName
    if ($null -eq $group.Tags)
    {
        Set-AzureRmResourceGroup -Name $ResourceGroupName -Tag @{ CurrentKeys = $tagValue }
    }
    else
    {
        $tags = $group.Tags
        $tags['CurrentKeys'] = $tagValue
        Set-AzureRmResourceGroup -Tag $tags -Name $ResourceGroupName
    }
}

# Decide whether to use primary or secondary keys for this deployment
# We do this based on the presence of a tag on the resource group - if it's set to 'Primary' then we switch the next deployment to use secondary keys; if the tag is absent or set to any value other than 'Primary' then we use the primary keys
# To select at random instead of using a resource group tag, use this line:
#   $usePrimaryKey = [System.Convert]::ToBoolean((Get-Random 2))
$usePrimaryKey = GetUsePrimaryKeyTag -ResourceGroupName $ResourceGroupName

Write-Host "Using $(&{if($usePrimaryKey) { 'primary' } else { 'secondary' }}) keys."

# Deploy ARM template
$armTemplateOutputs = New-AzureRmResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile (Join-Path $PSScriptRoot 'template.json') `
    -usePrimaryKey $usePrimaryKey `
    -Mode Complete `
    -Verbose -Force
$storageAccountName = $armTemplateOutputs.Outputs['storageAccountName'].Value
$cosmosDBAccountName = $armTemplateOutputs.Outputs['cosmosDBAccountName'].Value
$serviceBusNamespaceName = $armTemplateOutputs.Outputs['serviceBusNamespaceName'].Value
$testerFunctionUrl = $armTemplateOutputs.Outputs['testerFunctionUrl'].Value

# Re-tag the resource group to indicate that we're now using the primary/secondary keys
UpdateUsePrimaryKeyTag -ResourceGroupName $ResourceGroupName -UsePrimaryKey $usePrimaryKey

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
