#Import Az.ResourceGraph (not required as loaded via requirements.psd1)
#Import AzTable (used for the cloud table interactions)
#Every 5 minutes  0 */5 * * * *

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
$functionplanname = $env:FUNC_STOR_PlanName #'savtechosexecute"

try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName `
            -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable –Name $tableName –Context $storageContext).CloudTable
}
catch {
    $statusGood = $false
    Write-Host "Failure connecting to table for user data, $_"
}

#Get a link to the main remove function
#$functionApp = Get-AzWebAppSlot -Name $functionplanname -ResourceGroup $resourceGroupName -Slot Production
#$functionSecrets = Invoke-AzResourceAction -ResourceId ("{0}/functions/{1}" -f $functionApp.Id, $functionplanname) -Action "listkeys" -ApiVersion "2019-08-01" -Force

if($statusGood)
{
    #If go this path this has to go in key vault!!!
    $URIValue = "https://savtechosexecute.azurewebsites.net/api/VMGroupMemberModify?code=iFOjL0gKsnwupkmkonVLQlxsySsa8ENYXp8iuXgXAjaNvnRNNEwoCA=="

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
            $BodyObject = [PSCustomObject]@{"Action"="Remove";"CompName"=$record.RowKey;"SecPrincipal"=$record.Principal;"TargetLocalGroup"="administrators"}
            $BodyJSON = ConvertTo-Json($BodyObject)
            $response = Invoke-WebRequest -Uri $URIValue -Method POST -Body $BodyJSON -ContentType 'application/json'
            if($response.StatusCode -ne 200) #a problem
            {
                $statusGood = $false
                Write-Host "Error trying to remove user. Error data returned was $($response.StatusCode) $($response.Content)"
            }
            else
            {
                Write-Host "User remove call completed succesfully. Data returned was $($response.StatusCode) $($response.Content)"
            }
        }
    }

    Write-Host "** Cleanup execution completed **"
}