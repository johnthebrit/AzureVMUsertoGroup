#Simple Test Harness to call a rest API
#$URIValue = "https://savtechosexecute.azurewebsites.net/api/VMGroupMemberModify?code==="

#add someone
$BodyObject = [PSCustomObject]@{"Action"="Add";"CompName"="savazuusscwin10";"SecPrincipal"="savilltech\bruce";"TargetLocalGroup"="administrators"}
$BodyJSON = ConvertTo-Json($BodyObject)
$response = Invoke-RestMethod -Uri $URIValue -Method POST -Body $BodyJSON -ContentType 'application/json'

#audit
$BodyObject = [PSCustomObject]@{"Action"="Audit";"CompName"="savazuusscwin10";"TargetLocalGroup"="administrators"}
$BodyJSON = ConvertTo-Json($BodyObject)
$response = Invoke-RestMethod -Uri $URIValue -Method POST -Body $BodyJSON -ContentType 'application/json'
$response

#remove
$BodyObject = [PSCustomObject]@{"Action"="Remove";"CompName"="savazuusscwin10";"SecPrincipal"="savilltech\bruce";"TargetLocalGroup"="administrators"}
$BodyJSON = ConvertTo-Json($BodyObject)
$response = Invoke-RestMethod -Uri $URIValue -Method POST -Body $BodyJSON -ContentType 'application/json'