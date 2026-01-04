# Variables
# PVS Variables
param (
    [Parameter(Mandatory=$true)]
    [string]$vDiskName
)
$SrcSmbHostandSharePath = "" # Path to PVS vDisk Share \\server\share

# Azure Connection Variables
$AzureClientId = "" # Citrix SPN that has permissions on subscription for Citrix Administration
$AzureClientSecret = "" # Secret for SPN
$AzureSubscriptionId = "" # Subscription where resources will be created
$AzureTenantId = "" # Tenant ID for Azure AD

# Azure Build VM Variables
$location    = "" # Azure region
$rgName      = "" # Resource Group name
$SCSIvmSize      = "Standard_D2a_v4" # VM Size for Build VM
$NVMEvmSize      = "Standard_D2ads_v6" # VM Size for Machine Profile VM
$vnetRG	     = "" # Resource Group where VNet is located
$vnetName    = "" # VNet Name
$subnetName  = "" # Subnet Name
$vmName      = "BuildVM" # Name of the temporary VM used for image conversion from SCSI to NVME
$MPvmname    = "MachineProfile" # Name of the VM used for Machine Profile and Machine Catalog Creation

$MCSDiskName = "$vdiskName-MCS"
$imageName   = "$vdiskName-image"
$IsHibernateSupported = @{Name='IsHibernateSupported';Value='False'}
$IsAcceleratedNetworkSupported = @{Name='IsAcceleratedNetworkSupported';Value='True'}
#$ConfidentialVMSupported = @{Name='SecurityType';Value='None'}
$NVMESupported = @{Name='DiskControllerTypes';Value='SCSI, NVMe'}
$features = @($IsHibernateSupported,$IsAcceleratedNetworkSupported,$NVMESupported)

# Azure Shared Image Gallery Variables
$galleryName      = "Gallery$location"
$imageDefName     = "v6Convert"
$publisher        = "Citrix"
$offer            = "IPS"
$sku              = "MCS"

# IPS Appliance Variables
$ALApplianceAddress = "applayering.home.lab" # Address of the on-prem IPS Appliance
$ALport   = "443" # Port of the on-prem IPS Appliance
$AlConnectorConfig = "Azure-IPS" # Name of the Connector Config in the IPS Appliance for Azure
$imagescleanup = $true # Set to $true to cleanup managed disks and images after Shared Image Gallery captures


#####################################################################
# Change nothing below this line unless you know what you are doing
#####################################################################



##################################################################
# Functions
###################################################################
function New-AzureVM {
    param (
        [Parameter(Mandatory=$true)]
        [string]$vmName,

        [Parameter(Mandatory=$true)]
        [string]$DiskName,

        [Parameter(Mandatory=$true)]
        [string]$vmSize
    )
$osDisk = Get-AzDisk -ResourceGroupName $rgName -DiskName $DiskName
$nicName     = "$vmName-NIC"
$vnet   = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
$existing = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -ErrorAction SilentlyContinue
if ($existing) {
    Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -Force
}
$nic    = New-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -Location $location -SubnetId $subnet.Id
$vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize | Set-AzVMBootDiagnostic -disable
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
$vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $osDisk.Id -CreateOption Attach -Windows
New-AzVM -ResourceGroupName $rgName -Location $location -VM $vmConfig 
Write-Host "VM $vmName created."
Stop-AzVM -ResourceGroupName $rgName -Name $vmName -Force
Write-Host "VM $vmName deallocated."
}

function Remove-AzureVM {
    param (
        [Parameter(Mandatory=$true)]
        [string]$vmName
    )
$vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName
$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
Remove-AzVM -ResourceGroupName $rgName -Name $vmName -Force
$nicName = (Split-Path -Path $nicId -Leaf)
Remove-AzNetworkInterface -ResourceGroupName $vnetRG -Name $nicName -Force
$osDiskName = (Split-Path -Path $osDiskId -Leaf)
Remove-AzDisk -ResourceGroupName $rgName -DiskName $osDiskName -Force
Write-Host "VM $vmName and associated resources removed."
}

function Update-BuildVdisk {
    param (
        [Parameter(Mandatory=$true)]
        [string]$vmName,

        [Parameter(Mandatory=$true)]
        [string]$DiskName
    )
Stop-AzVM -ResourceGroupName $rgName -Name $vmName -Force
Write-Host "VM deallocated."
$vm.StorageProfile.OsDisk.ManagedDisk.Id = $newDiskId
$newDiskName = ($newDiskId.Split("/") | Select-Object -Last 1)
$vm.StorageProfile.OsDisk.Name = $newDiskName
Update-AzVM -ResourceGroupName $rgName -VM $vm
Write-Host "OS disk on VM $vmName updated to $newDiskName."
if ($newDiskName -ne $previousDiskName) {
$script:diskupdated = $true
}
else {
}
}

###################################################
# Main Script
###################################################

# Begin Logging
$LogFileTimeStamp = Get-Date -Format "MM-dd-yyyy-HH-mm-tt"
$transcriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PVSDiskMigration-$LogFileTimeStamp.log"
Start-Transcript -Path $transcriptPath -Force

# Validate access to PVS file share.  Exit if not accessible.
try {
    if (Test-Path $SrcSmbHostandSharePath\$vDiskName) {
        Write-Host "PVS File share, and $vDiskName is accessible."
    }
    else {
        Write-Host "PVS File share is NOT accessible, or $vDiskName does not exist. Run this from a machine and user that has access to the share.  If running from a non-domain joined machine, use net use to connect to the share with a proper account.  Exiting script."
        Stop-Transcript
        exit 1
    }
}
catch {
    Stop-Transcript
    exit 1
}

# Validate access to Connector Appliance. Exit if not accessible.
try {
$result = Test-NetConnection -ComputerName $ALApplianceAddress -Port $ALport
Write-Progress -Activity "AL Test Done" -Completed

if ($result.TcpTestSucceeded) {
    Write-Host "Server $ALApplianceAddress is responding on port $ALport."
}
else {
    Write-Host "Server $ALApplianceAddress  is NOT responding on port $ALport."
    Stop-Transcript
    exit 1
}
}
catch {
    Stop-Transcript
    exit 1
}
# Connect to Azure
$SecureStringPwd = $AzureClientSecret | ConvertTo-SecureString -AsPlainText -Force
$pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AzureClientId, $SecureStringPwd
Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $AzureTenantId -Subscription $AzureSubscriptionId

# Connect to IPS Appliance
Connect-AlAppliance -Address $ALApplianceAddress -Credential (Get-Credential) -IgnoreCertificateErrors

# Upload the disk to Azure
# Check if the disk already exists, and upload only if it does not exists.
$disk = Get-AzDisk -ResourceGroupName $rgName -DiskName $vDiskName -ErrorAction SilentlyContinue

if ($null -eq $disk) {
Write-Host "Disk '$vDiskName' does NOT exist in resource group '$rgName'."
Write-Host "Uploading now"
 $CopyParams = @{
    FileName        = "$SrcSmbHostandSharePath\$vDiskName"
    ManagedDiskName = $vDiskName
    Location        = $location
    ResourceGroup   = $rgName
    SubscriptionId  = $AzureSubscriptionId
    TenantId        = $AzureTenantId
    ClientId        = $AzureClientId
    Secret          = $AzureClientSecret
}
Copy-DiskToAzure @CopyParams
Write-Host "PVS Disk has been uploaded to Azure."
Clear-Host
}
else {
    Write-Host "Disk '$vDiskName' already exists in resource group '$rgName'."
    Write-Host "Continuing to IPS Conversion."
}


# Prepare image for MCS
# First check if the disk already exists, and if it doesn't then create it.
$disk = Get-AzDisk -ResourceGroupName $rgName -DiskName $MCSDiskName -ErrorAction SilentlyContinue

if ($null -eq $disk) {
Write-Host "Disk '$MCSDiskName' does NOT exist in resource group '$rgName'."
Write-Host "Converting now"
$sourcedisk = "/subscriptions/$AzureSubscriptionId/resourceGroups/$rgName/providers/Microsoft.Compute/disks/$vDiskName"

Start-AlIpsPrepare -ConnectorConfigId (Get-AlConnectorConfig -Name $AlConnectorConfig).Id -ProvisioningType Mcs -SourceDisk $sourcedisk -OutputDiskName $MCSDiskName  -Misa Install -Mcsio Install  -EnableRdp -DebugSettings @{enableBootDiagnostics = $true} | Wait-AlTask | Select-Object -ExpandProperty WorkItems
}
else {
    Write-Host "Disk '$MCSDiskName' already exists in resource group '$rgName'."
    Write-Host "Continuing to NVME Conversion."
}
Write-Progress -Activity "MCS Conversion Done" -Completed
Clear-Host
# Create Managed Image of converted MCS disk
$newDiskId  = "/subscriptions/$AzureSubscriptionId/resourceGroups/$rgName/providers/Microsoft.Compute/disks/$MCSDiskName" 

$vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    Write-Host "VM $vmName does not exist in resource group $rgName."
    Write-Host "Creating $vmName"
    New-AzureVM -vmName $vmName -DiskName $MCSDiskName -VMSize $SCSIvmSize
    $diskupdated = $false
}
else {
    Write-Host "Build VM $vmName already exists."
    Write-Host "Changing OS Disk to $MCSDiskName"
    $previousDiskName = $vm.StorageProfile.OsDisk.Name
    Update-BuildVdisk -vmName $vmName -DiskName $MCSDiskName
}

# Check for Image Definition in Gallery
$imageDef = Get-AzGalleryImageDefinition -ResourceGroupName $rgName -GalleryName $galleryName -Name $imageDefName -ErrorAction SilentlyContinue
$gallery = Get-AzGallery -ResourceGroupName $rgName -GalleryName $galleryName -ErrorAction SilentlyContinue
if ($null -eq $imageDef) {
    Write-Host "Image Definition '$imageDefName' does NOT exist."
    if ($null -eq $gallery) {
        Write-Host "Gallery '$galleryName' does NOT exist."
        Write-Host "Creating Gallery '$galleryName'"
        New-AzGallery -ResourceGroupName $rgName -Name $galleryName -Location $location -Description "NVMe Conversion Gallery in $location"
    }
    else {
        Write-Host "Gallery '$galleryName' already exists."
    }
    Write-Host "Creating Image Definition '$imageDefName'"
    New-AzGalleryImageDefinition -ResourceGroupName $rgName -GalleryName $galleryName -Name $imageDefName -Location $location -OsType Windows -OsState Generalized -Publisher $publisher -Offer $offer -Feature $features -HyperVGeneration "V2" -Sku $sku 
}
else {
    Write-Host "Image Definition '$imageDefName' already exists."
    Write-Host "Capturing Image to NVMe Now"
}
$vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName
$imageConfig = New-AzImageConfig -Location $location -HyperVGeneration V2
$imageConfig = Set-AzImageOsDisk -Image $imageConfig -OsState Generalized -OsType Windows -ManagedDiskId $vm.StorageProfile.OsDisk.ManagedDisk.Id 
New-AzImage -ImageName $imageName -ResourceGroupName $rgName -Image $imageConfig

$imageVersions = Get-AzGalleryImageVersion -ResourceGroupName $rgName -GalleryName $galleryName -GalleryImageDefinitionName $imageDefName -ErrorAction SilentlyContinue

if ($imageVersions) {
    # Extract highest version number
    $latestVersion = ($imageVersions | Sort-Object -Property Name -Descending | Select-Object -First 1).Name
    Write-Host "Latest version is $latestVersion"

    # Parse version string (format: Major.Minor.Revision)
    $parts = $latestVersion.Split(".")
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $revision = [int]$parts[2] + 1

    $newVersion = "$major.$minor.$revision"
}
else {
    # No versions exist yet, start with 1.0.0
    $newVersion = "1.0.0"
}

Write-Host "Creating new image version: $newVersion"
$managedImageId = "/subscriptions/$AzureSubscriptionId/resourceGroups/$rgName/providers/Microsoft.Compute/images/$imageName"
New-AzGalleryImageVersion `
    -ResourceGroupName $rgName `
    -GalleryName $galleryName `
    -GalleryImageDefinitionName $imageDefName `
    -Name $newVersion `
    -Location $location `
    -SourceImageId $managedImageId `
    -PublishingProfileEndOfLifeDate (Get-Date).AddYears(3) `
    -ReplicaCount 1

### Create NVME image for Machine Profile Computer
$latestImageVersion = Get-AzGalleryImageVersion -ResourceGroupName $rgName -GalleryName $galleryName -GalleryImageDefinitionName $imageDefName |  Sort-Object -Property Name -Descending |  Select-Object -First 1

$diskName = $latestImageVersion.Name
$galleryImageReference = @{Id = $latestImageVersion.Id}
$diskConfig = New-AzDiskConfig -Location $location -CreateOption FromImage -GalleryImageReference $galleryImageReference -OsType Windows

New-AzDisk -ResourceGroupName $rgName -DiskName $diskName -Disk $diskConfig

$vm = Get-AzVM -ResourceGroupName $rgName -Name $MPvmname -ErrorAction SilentlyContinue

  if ($null -eq $vm) {
    } else {
Remove-AzureVM -vmName $MPvmname
    }
New-AzureVM -vmName $MPvmname -DiskName $diskName -VMSize $NVMEvmSize 

# Images cleanup
If ($imagescleanup -eq $true) {
    If ($diskupdated -eq $true) {
        Write-Host "Removing MCS Managed Disk: $previousDiskName"
        Remove-AzDisk -ResourceGroupName $rgName -DiskName $previousDiskName -Force
    } else {
    }
Write-Host "Removing Uploaded PVS Disk: $vDiskName"
Remove-AzDisk -ResourceGroupName $rgName -DiskName $vDiskName -Force
Write-Host "Removing MCS Imaged Disk: $imageName"
Remove-AzImage -ResourceGroupName $rgName -ImageName $imageName -Force
}
else {
    Write-Host "You have opted to retain the intermediate disks and images."
    Write-Host "You will want to manually remove $vDiskName, $MCSDiskName, and $imageName when no longer needed."
    Write-Host "Or else you will incur ongoing charges for these resources."
}
Stop-Transcript