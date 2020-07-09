# AzureVMUsertoGroup
# Azure VM Local Group Provisioning Solution #

This solution is designed to enable users to be added to local groups of Azure VMs for a specified duration. Once the duration has expired the user assignment in the group will be automatically revoked. This is useful for temporary elevation to a local group membership, e.g. administrators.

Uses three PowerShell Azure Functions:

* VMList - Used to return list of all Windows VM in any subscription (triggered via REST API)
* VMGroupMemberModify - Used to add/remove/audit user to/from local group in VM (triggered via REST API)
* VMGroupCleanup - Function to scan additions that have expired and remove users from local groups on VMs (triggered on schedule)

The App Service that runs the three functions must have a system managed identity. This identity should be assigned the custom role defined in [VMReadandRunCommandCustomRole.json](VMReadandRunCommandCustomRole.json). This provides read access to VM objects (so they can be found) and also permission to use the RunCommand extension (for the add/remove/audit operations). This role can be given at management group/subscription levels.

__Note that the RunCommand runs the commands as system so the function and identity should be protected by running inside a restricted subscription__

A storage account must be created with two tables as defined in [TableCreate.ps1](TableCreate.ps1). The actual names can vary but must match the App Serivce application settings as defined in [RequiredAppVariables.json](RequiredAppVariables.json).