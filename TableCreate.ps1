$storageAccountName = "sasavusscuserelevate"
$resourceGroupName = 'RG-USSC-OSExecuteFunction'
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName
$storageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName `
  -Name $storageAccountName `
  -Location $resourceGroup.Location `
  -SkuName Standard_LRS `
  -Kind StorageV2

$storageContext = $storageAccount.Context

$tableName = "userelevationdata"
New-AzStorageTable –Name $tableName –Context $storageContext
$tableName2 = "userelevationlogs"
New-AzStorageTable –Name $tableName2 –Context $storageContext