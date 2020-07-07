using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

#Import Az.ResourceGraph (not required as loaded via requirements.psd1)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

#Set initial status
$statusGood = $true

# Interact with query parameters or the body of the request.
$action = $Request.Query.Action
$compname = $Request.Query.CompName
$secprincipal = $Request.Query.SecPrincipal
$targetlocalgroup = $Request.Query.TargetLocalGroup

if (-not $action) {
    $action = $Request.Body.Action
}
if (-not $compname) {
    $compname = $Request.Body.CompName
}
if (-not $secprincipal) {
    $secprincipal = $Request.Body.SecPrincipal
}
if (-not $targetlocalgroup) {
    $targetlocalgroup = $Request.Body.TargetLocalGroup
}

if($statusGood)
{
    if ($action -and $compname -and $targetlocalgroup) {
        #We can continue. As part of default profile.ps1 for functions if managed identity exists it is used to azconnect
        #That managed identity needs permissions on the management group (read) to find the computer OS and then the custom role
        #to use the runCommand extension Microsoft.Compute/virtualMachines/runCommand/action
        if((($action -eq "Add") -or ($action -eq "Remove")) -and ($null -eq $secprincipal))
        {
            $statusGood = $false
            $body = "No security principal passed. This is mandatory for Add or Remove action"
        }

        if($statusGood)
        {
            #Find the VM resource via the computername
            $GraphSearchQuery = "Resources
            | where type =~ 'Microsoft.Compute/virtualMachines'
            | where properties.osProfile.computerName =~ '$compname'
            | join (ResourceContainers | where type=='microsoft.resources/subscriptions' | project SubName=name, subscriptionId) on subscriptionId
            | project VMName = name, CompName = properties.osProfile.computerName, RGName = resourceGroup, SubName, SubID = subscriptionId"
            $VMresource = Search-AzGraph -Query $GraphSearchQuery

            if($null -eq $VMresource)
            {
                $statusGood = $false
                $body = "Could not find a matching VM resource for computer name $compname"
            }
            else
            {
                $body = "$action on $compname for $secprincipal into $targetlocalgroup for $duration."
                $body += "Resource found $($VMresource.VMName) in RG $($VMresource.RGName) in sub $($VMresource.Subname)($($VMresource.SubID))"

                #Change subscription here first!
                Select-AzSubscription -Subscription $VMResource.SubID

                #Call the runCommand extension to perform the required command
                $body += "$secprincipal $($secprincipal.contains("\")) "

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
                    $CommandToRun = "Get-LocalGroupMember -Group '$targetlocalgroup' | convertto-json"
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
