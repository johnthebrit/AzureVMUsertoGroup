#Import Az.ResourceGraph (not required as loaded via requirements.psd1)
#Import AzTable (used for the cloud table interactions)
#Every 5 minutes  0 */5 * * * *
#Every hour 0 0 */1 * * *

# Input bindings are passed in via param block.
param($Timer)

# Write to the Azure Functions log stream.
Write-Host "PowerShell VMGroupCleanup function processed a request."

#Set initial status
$statusGood = $true
$body = ""

$baseDate = Get-Date -Date "01/01/1970"

#Storage account information. Stored as environment variables
$resourceGroupName = $env:FUNC_STOR_RGName  #'RG-USSC-OSExecuteFunction'
$storageAccountName = $env:FUNC_STOR_ActName  #"sasavusscuserelevate"
$tableName = $env:FUNC_STOR_TblName #"userelevationdata"
$logTableName = $env:FUNC_STOR_LogTblName #"userelevationlogs"
$functionplanname = $env:FUNC_STOR_PlanName #'savtechosexecute"

try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName `
            -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable –Name $tableName –Context $storageContext).CloudTable
        $logTable = (Get-AzStorageTable –Name $logTableName –Context $storageContext).CloudTable
}
catch {
    $statusGood = $false
    Write-Host "Failure connecting to table for user data, $_"
}

try {
    #Get access token
    #$accessToken = az account get-access-token --query accessToken -o tsv
    $currentAzureContext = Get-AzContext
    $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
    $accessToken = $profileClient.AcquireAccessToken($currentAzureContext.Subscription.TenantId).AccessToken

    #Get a link to the main function
    $functionApp = Get-AzWebAppSlot -Name $functionplanname -ResourceGroup $resourceGroupName -Slot Production

    $listFunctionKeysUrl = "https://management.azure.com$($functionapp.Id)/functions/VMGroupMemberModify/listKeys?api-version=2018-02-01"
    $functionKeys = Invoke-RestMethod -Method Post -Uri $listFunctionKeysUrl `
        -Headers @{ Authorization="Bearer $accessToken"; "Content-Type"="application/json" }
    $keyToUse = $functionKeys.VMGroupCleanupKey

}
catch {
    $statusGood = $false
    Write-Host "Error getting token or key for use, $_"
}

if($statusGood)
{
    $URIValue = "https://savtechosexecute.azurewebsites.net/api/VMGroupMemberModify?code=$($keyToUse)"

    $currentTime = (Get-Date).ToUniversalTime()
    $currentTimeSeconds = [math]::Round((New-TimeSpan -Start $baseDate -End (Get-Date).ToUniversalTime()).TotalSeconds)

    Write-Host "** Starting cleanup execution with current time $currentTime ($currentTimeSeconds) **"

    $records = Get-AzTableRow `
        -table $cloudTable #`
        #-CustomFilter "ExpiryTimeSeconds lt $currentTimeSeconds"

    foreach($record in $records)
    {
        if($record.ExpiryTimeSeconds -lt $currentTimeSeconds)
        {
            Write-Host "Removing $($record.Principal) from $($record.GroupName) on machine $($record.OSName)"
            $BodyObject = [PSCustomObject]@{"Action"="Remove";"CompName"=$record.RowKey;"SecPrincipal"=$record.Principal;"TargetLocalGroup"="$($record.GroupName)"}
            $BodyJSON = ConvertTo-Json($BodyObject)
            $response = Invoke-WebRequest -Uri $URIValue -Method POST -Body $BodyJSON -ContentType 'application/json'

            $tablePrincipalName = $record.Principal.Replace("\","") #\not legal character for the row or partition id
            $rowkeyvalue = "$($record.RowKey)-$currentTimeSeconds"

            if($response.StatusCode -ne 200) #a problem
            {
                #Partitionkey and rowkey must be unique combination in table so use timestamp as part of rowkey
                $statusGood = $false
                Write-Host "Error trying to remove user. Error data returned was $($response.StatusCode) $($response.Content)"
                try
                {
                    Add-AzTableRow `
                        -table $logTable `
                        -partitionKey $tablePrincipalName `
                        -rowKey $rowkeyvalue -property @{"LogType"="Error";"Message"="Failure removing $($record.Principal) from $($record.GroupName) on machine $($record.OSName)";"Principal"="$($record.Principal)";"OSName"="$($record.OSName)";"GroupName"="$($record.GroupName)";"ResourceGroup"="$($record.ResourceGroup)";"Subscription"="$($record.subscription)";}
                }
                catch {
                    $statusGood = $false
                    Write-Host = "Failure creating table entry for process execution entry $tablePrincipalName $rowkeyvalue, $_"
                }
            }
            else
            {
                Write-Host "User remove call completed succesfully. Data returned was $($response.StatusCode) $($response.Content)"
                try
                {
                    Add-AzTableRow `
                        -table $logTable `
                        -partitionKey $tablePrincipalName `
                        -rowKey $rowkeyvalue -property @{"LogType"="Information";"Message"="Removed $($record.Principal) from $($record.GroupName) on machine $($record.OSName)";"Principal"="$($record.Principal)";"OSName"="$($record.OSName)";"GroupName"="$($record.GroupName)";"ResourceGroup"="$($record.ResourceGroup)";"Subscription"="$($record.subscription)";}
                }
                catch {
                    $statusGood = $false
                    Write-Host = "Failure creating table entry for process execution entry $tablePrincipalName $rowkeyvalue, $_"
                }
            }
        }
    }

    Write-Host "** Cleanup execution completed **"
}