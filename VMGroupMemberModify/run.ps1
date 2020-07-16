using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

#Import Az.ResourceGraph (not required as loaded via requirements.psd1)
#Import AzTable (used for the cloud table interactions)
# Import-Module "D:\home\site\wwwroot\VMGroupMemberModify\Az.ResourceGraph\Az.ResourceGraph.psd1"

# Write to the Azure Functions log stream.
Write-Host "PowerShell VMGroupMemberModify function processed a request."

#Set initial status
$statusGood = $true

#Storage account information. Stored as environment variables
$resourceGroupName = $env:FUNC_STOR_RGName  #'RG-USSC-OSExecuteFunction'
$storageAccountName = $env:FUNC_STOR_ActName  #"sasavusscuserelevate"
$tableName = $env:FUNC_STOR_TblName #"userelevationdata"
try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName `
        -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable –Name $tableName –Context $storageContext).CloudTable
}
catch {
    $statusGood = $false
    $body = "Failure connecting to table for user data, $_"
}


# Interact with query parameters or the body of the request.
$action = $Request.Query.Action
$compname = $Request.Query.CompName
$duration = $Request.Query.Duration
$secprincipal = $Request.Query.SecPrincipal
$targetlocalgroup = $Request.Query.TargetLocalGroup

$baseDate = Get-Date -Date "01/01/1970"

if (-not $action) {
    $action = $Request.Body.Action
}
if (-not $compname) {
    $compname = $Request.Body.CompName
}
if (-not $duration) {
    $duration = $Request.Body.Duration
}
if (-not $secprincipal) {
    $secprincipal = $Request.Body.SecPrincipal
}
if (-not $targetlocalgroup) {
    $targetlocalgroup = $Request.Body.TargetLocalGroup
}

$durationinMinutes = -1
if($statusGood)
{
    if ($action -and $compname -and $targetlocalgroup) {
        #We can continue. As part of default profile.ps1 for functions if managed identity exists it is used to azconnect
        #That managed identity needs permissions on the management group (read) to find the computer OS and then the custom role
        #to use the runCommand extension Microsoft.Compute/virtualMachines/runCommand/action
        if(($action -eq "Add") -and (($null -eq $duration) -or ($null -eq $secprincipal)))
        {
            $statusGood = $false
            $body = "No duration and/or security principal passed. This is mandatory for Add action"
        }
        if(($action -eq "Remove") -and ($null -eq $secprincipal))
        {
            $statusGood = $false
            $body = "No security principal passed. This is mandatory for Remove action"
        }

        if($action -eq "Add" -and $statusGood)
        {
            #Convert the duration to time
            if($duration -eq "0")
            {
                $durationinMinutes = 0
            }
            else
            {
                #unit is last character minutes, hours or days. m, h or d
                $durationUnit = $duration.Substring($duration.Length -1)
                $durationValue = [int]($duration.Substring(0, ($duration.Length -1)))
                if($durationValue -le 9999)
                {
                    switch ($durationUnit)
                    {
                        'm'
                        { $durationinMinutes=$durationValue }
                        'h'
                        { $durationinMinutes=$durationValue * 60 }
                        'd'
                        { $durationinMinutes=$durationValue * 1440}
                        'l'
                        {   $statusGood = $false
                            $body = "Light years (l) is not a valid duration unit. m, h and d only"}
                        Default
                        {
                            $statusGood = $false
                            $body = "Unknown unit type. Must be m, h or d"
                        }
                    }
                }
                else
                {
                    $statusGood = $false
                    $body = "Value must be less than 9999. If no expiry set to 0"
                }

            }
        }

        if($statusGood)
        {
            #Find the VM resource via the computername
            $GraphSearchQuery = "Resources
            | where type =~ 'Microsoft.Compute/virtualMachines'
            | where properties.osProfile.computerName =~ '$compname'
            | join (ResourceContainers | where type=='microsoft.resources/subscriptions' | project SubName=name, subscriptionId) on subscriptionId
            | project VMName = name, CompName = properties.osProfile.computerName, OSType = properties.storageProfile.osDisk.osType, RGName = resourceGroup, SubName, SubID = subscriptionId"
            $VMresource = Search-AzGraph -Query $GraphSearchQuery

            if($null -eq $VMresource)
            {
                $statusGood = $false
                $body = "Could not find a matching VM resource for computer name $compname"
            }
            elseif ($VMresource.OSType -ne "Windows")
            {
                $statusGood = $false
                $body = "Associated VM for $compname is not Windows, $($VMresource.VMName) in RG $($VMresource.RGName) in sub $($VMresource.Subname). This function only supports Windows VMs"
            }
            else
            {
                $body = "$action on $compname for $secprincipal into $targetlocalgroup for $duration."
                $body += "Resource found $($VMresource.VMName) in RG $($VMresource.RGName) in sub $($VMresource.Subname)($($VMresource.SubID))"

                #Change subscription here first!
                Select-AzSubscription -Subscription $VMResource.SubID

                #Call the runCommand extension to perform the required command
                if(($action -eq "Add") -or ($action -eq "Remove"))
                {
                    $body += "$secprincipal $($secprincipal.contains("\")) "
                }

                if($action -eq "Add")
                {
                    $CommandToRun = "Add-LocalGroupMember -Group '$targetlocalgroup' -Member '$secprincipal'"
                }
                elseif($action -eq "Remove") #assume Remove
                {
                    $CommandToRun = "Remove-LocalGroupMember -Group '$targetlocalgroup' -Member '$secprincipal'"
                }
                else #assume Audit
                {
                    #$CommandToRun = "Get-LocalGroupMember -Group '$targetlocalgroup' | convertto-json" #does not handle sids
                    $CommandToRun = @"
                    `$group = [ADSI]"WinNT://`$env:COMPUTERNAME/$targetlocalgroup"
                    `$group_members = @(`$group.Invoke('Members') | % {([adsi]`$_).path})
                    `$group_members | convertto-json
"@
                }

                $body += $CommandToRun

                $TempFileName = "$((New-Guid).Guid).ps1"

                Set-Content -Path $env:temp\$TempFileName -Value $CommandToRun
                try {
                    $ErrorActionPreference = "Stop"; #Make all errors terminating as Invoke-AzVMRunCommand marked delete is non-terminating but want caught
                    $result = Invoke-AzVMRunCommand -ResourceGroupName $VMresource.RGName -Name $VMresource.VMName `
                        -CommandId 'RunPowerShellScript' -ScriptPath $env:temp\$TempFileName
                }
                catch {
                    #Try to clean up the extension
                    $result = Invoke-AzVMRunCommand -ResourceGroupName $VMresource.RGName -Name $VMresource.VMName `
                        -CommandId 'RemoveRunCommandWindowsExtension'
                    if($result) #if reset worked try again then let continue
                    {
                        $result = Invoke-AzVMRunCommand -ResourceGroupName $VMresource.RGName -Name $VMresource.VMName `
                            -CommandId 'RunPowerShellScript' -ScriptPath $env:temp\$TempFileName
                        if(!$result) #still failing we give up!
                        {
                            $statusGood = $false
                            $body = "Failure running Invoke-AzVMRunCommand, $_"
                        }
                    }
                }
                finally{
                    $ErrorActionPreference = "Continue"; #Reset the error action pref to default
                }

                Remove-Item $env:temp\$TempFileName

                if(($result.status -eq "Succeeded") -and ($action -ne "Audit")) #no table update if audit only and not infinite duration
                {

                    $tablePrincipalName = $secprincipal.Replace("\","") #\not legal character for the row or partition id
                    #Add or update the table
                    $expiryTime = (Get-Date).ToUniversalTime().AddMinutes($durationinMinutes)
                    $expiryTimeSeconds = [math]::Round((New-TimeSpan -Start $baseDate -End $expiryTime).TotalSeconds)

                    try {
                        #Check if record exists for the user and guest OS
                        $record = Get-AzTableRow `
                            -table $cloudTable `
                            -PartitionKey "$tablePrincipalName" -RowKey ($VMresource.VMName)

                        if($action -eq "Add")
                        {
                            if(!$record -and ($duration -ne "0")) #if does not exist and its not duration 0
                            {
                                #Create
                                Add-AzTableRow `
                                    -table $cloudTable `
                                    -partitionKey $tablePrincipalName `
                                    -rowKey ($VMresource.VMName) -property @{"ExpiryTime"="$expiryTime";"ExpiryTimeSeconds"="$expiryTimeSeconds";"Principal"="$secprincipal";"OSName"="$compname";"GroupName"="$targetlocalgroup";"ResourceGroup"="$($VMresource.RGName)";"Subscription"="$($VMResource.SubID)";}
                            }
                            else
                            {
                                if($duration -ne "0")
                                {
                                    #Need to update the expiry time. This assumes this new record should overwrite the existing even if potentially existing was a later time
                                    $record.ExpiryTime = "$expiryTime"
                                    $record | Update-AzTableRow -table $cloudTable #commit the change
                                }
                                else #remove the record as we no longer have an expiry
                                {
                                    $record | Remove-AzTableRow -table $cloudTable
                                }
                            }
                        }
                        else #assume Remove
                        {
                            if($record) #if does exist
                            {
                                $record | Remove-AzTableRow -table $cloudTable
                            }
                        }
                    }
                    catch {
                        $statusGood = $false
                        $body = "Failure creating table entry for user but elevation was performed, $_"
                    }
                }

            }
            if($statusGood)
            {
                $status = [HttpStatusCode]::OK
                $body += "Result - $($result.status)"
            }
        }
    } #end of check if all parameters passed
    else
    {
        $statusGood = $false
        $body = "Please pass all required parameters on the query string or in the request body."
    }
} #end of if statusgood

if(!$statusGood)
{
    $status = [HttpStatusCode]::BadRequest
}

if($action -eq "Audit" -and $statusGood)
{
    $BodyJSON = ConvertTo-Json($result.Value[0].Message)
}
else
{
    $BodyJSON = "{`"Success`":`"$statusgood`",`"Info`":`"$(ConvertTo-Json($body))`"}"
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $BodyJSON
})
