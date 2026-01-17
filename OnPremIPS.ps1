######################################################################
# Script Created by: Jeff Riechers
# Date Created: January 2026
# Please contact me for any questions: https://github.com/jeffriechers/AzureSCSItoNVMeConversionofIPS
#
# Usage: .\OnPremIPS.ps1 -vDiskName "Win10-22H2x64.vhdx"
#
# Description: This script uploads an on-prem PVS vDisk to Azure, converts it to an MCS-compatible SCSI disk using Citrix IPS,
#              then converts that disk to an NVMe disk suitable for Machine Profiles and Machine Catalogs in Citrix Virtual Apps and Desktops.
# 
# Prerequisites:
# - Azure PowerShell Module installed
# - Citrix PoshSDK Module installed if not running on Delivery Controller
# - Appropriate permissions in Azure for creating resources via Service Principal
# - Access to the on-prem PVS vDisk share
# - An on-prem Citrix App Layering Appliance 2511+ configured with an Azure Connector for IPS
# - Credentials on the Citrix App Layering Appliance to use the IPS functions
# - Citrix.Applayering Powershell Module installed "Install-Module -Name "Citrix.AppLayering" -Scope CurrentUser"
# - Citrix.Image.Uploader PowerShell Module installed "Install-Module -Name "Citrix.Image.Uploader" -Scope CurrentUser"
# - To use Web Studio Image Management, the installed VDA 2402 (any CU) or VDA 2507 vanilla ONLY is required. 2507 CU1 and 2511 VDA are not supported at this time.
# - Modify the variables below to match your environment before running.
#####################################################################


# Variables
# PVS Variables
param (
    [Parameter(Mandatory = $true)]
    [string]$vDiskName # Name of the PVS vDisk to be converted (example: Win10-22H2x64.vhdx) brought in as script parameter
)
$SrcSmbHostandSharePath = "" # Path to PVS vDisk Share \\server\share

# Azure Connection Variables
$AzureClientId = "" # Citrix SPN that has permissions on subscription for Citrix Administration
$AzureClientSecret = "" # Secret for SPN
$AzureSubscriptionId = "" # Subscription where resources will be created
$AzureTenantId = "" # Tenant ID for Azure AD

# Azure Build VM Variables
$location = "" # Azure region
$rgName = "" # Resource Group name for storing Disk Images, VMs, and Image Galleries
$SCSIvmSize = "Standard_D2a_v4" # VM Size for Build VM
$NVMEvmSize = "Standard_D2ads_v6" # VM Size for Machine Profile VM
$vnetRG = "" # Resource Group where VNet is located
$vnetName = "" # VNet Name
$subnetName = "" # Subnet Name
$vmName = "BuildVM" # Name of the temporary VM used for image capture from SCSI to NVMe Shared Image Gallery Defintion
$MPvmname = "MachineProfile" # Name of the VM used for Machine Profile and Machine Catalog Creation built from NVMe Image

$MCSDiskName = "$vdiskName-MCS" #This will be the name of the Image created by IPS for MCS use for SCSI Images
$imageName = "$vdiskName-image" #This is the temporary managed used in the NVMe image converstion process
$IsHibernateSupported = @{Name = 'IsHibernateSupported'; Value = 'False' } # Azure VM Flat to enable/disable hibernate support
$IsAcceleratedNetworkSupported = @{Name = 'IsAcceleratedNetworkSupported'; Value = 'True' } # Azure VM Flag to enable/disable Accelerated Networking
$NVMESupported = @{Name = 'DiskControllerTypes'; Value = 'SCSI, NVMe' } # Azure VM Flag to enable NVMe support (required for NVMe images)
$features = @($IsHibernateSupported, $IsAcceleratedNetworkSupported, $NVMESupported) # Variable to hold all features for Image Definition creation

# Azure Shared Image Gallery Variables
$galleryName = "SharedImageGallery_$rgName" # Name of the Shared Image Gallery used for NVMe Images, will also be re-used for Citrix Web Studio Image Management
$imageDefName = "v6Convert" # Name of the Shared Image Definition used for converting NVMe Images
$publisher = "Citrix" # Publisher Name for Shared Image Gallery details
$offer = "IPS" # Offer Name for Shared Image Gallery details
$sku = "MCS" # SKU Name for Shared Image Gallery details

# IPS Appliance Variables
$ALApplianceAddress = "" # Address of the on-prem IPS Appliance, IP or FQDN
$ALport = "443" # Port of the on-prem IPS Appliance (Script already is set to accept self-signed certs)
$AlConnectorConfig = "" # Name of the Connector Config in the IPS Appliance for Azure (Ensure it is setup for Azure IPS, and not for Azure App Layering)
$imagescleanup = $true # Set to $true to cleanup managed disks and images after Shared Image Gallery captures (recommended).  Set to $false to retain all intermediate disks and images during testing runs.  Will incur ongoing charges if not removed, and you will be notified of this in the logs.

# Web Studio Image Management Settings
$DDC = "" # On-Prem Delivery Controller FQDN for placing NVMe Images into Web Studio Image Management (Requires VDA 2402 - any CU, or 2507 vanilla ONLY at this point 2507 CU1 and 2511 VDA are not supported at this time.)
$HVConnectionName = "" # Azure Hypervisor Connection Name as seen in Studio, this is the name under the Microsoft Azure TM Hosting Connection.  If you specify the Microsoft Azure TM Hosting Connection this will fail.
$WSImageDefName = "" # Name of the Image Definition as it will appear in Web Studio Image Management, and in the Azure Shared Image Gallery.
$OSType = "Windows" # Possible values: "Windows" or "Linux"
$SessionType = "MultiSession" # Possible values: "SingleSession" or "MultiSession"
$UseSharedImageGallery = $true # Variable to indicate use of Shared Image Gallery in Web Studio Image Management, $true is the only supported option at this point.  Future Scripts will allow modifying this to use dedicated Galleries

#####################################################################
# Change nothing below this line unless you know what you are doing
#####################################################################



##################################################################
# Functions
###################################################################
function New-AzureVM {
    param (
        [Parameter(Mandatory = $true)]
        [string]$vmName,

        [Parameter(Mandatory = $true)]
        [string]$DiskName,

        [Parameter(Mandatory = $true)]
        [string]$vmSize
    )
    $osDisk = Get-AzDisk -ResourceGroupName $rgName -DiskName $DiskName
    $nicName = "$vmName-NIC"
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    $existing = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -Force
    }
    $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $vnetRG -Location $location -SubnetId $subnet.Id
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
        [Parameter(Mandatory = $true)]
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
        [Parameter(Mandatory = $true)]
        [string]$vmName,

        [Parameter(Mandatory = $true)]
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
function New-Image {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DiskName
    )
    $result = Test-ProvImageDefinitionNameAvailable -ImageDefinitionName $WSImageDefName -AdminAddress $DDC

    if ($result.Available) {
        Write-Host "Image definition name is available."
        New-ProvImageDefinition -ImageDefinitionName $WSImageDefName -OsType $OSType -VdaSessionSupport $SessionType -AdminAddress $DDC
        $CustomProperties = @"
<CustomProperties xmlns="http://schemas.citrix.com/2014/xd/machinecreation" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <Property xsi:type="StringProperty" Name="UseSharedImageGallery" Value="$UseSharedImageGallery" />
    <Property xsi:type="StringProperty" Name="ResourceGroups" Value="$rgName" />
     <Property xsi:type="StringProperty" Name="ImageGallery" Value="$galleryName" />
</CustomProperties>
"@
        Add-ProvImageDefinitionConnection -ImageDefinitionName $WSImageDefName -HypervisorConnectionName $HVConnectionName -CustomProperties $CustomProperties -AdminAddress $DDC
    } 
    else {
        Write-Host "Image definition name already exists."
    }

    # Create new image version
    $TimeStamp = Get-Date -Format "MM-dd-yyyy-HH-mm-tt"
    $imageVersion = New-ProvImageVersion -ImageDefinitionName $WSImageDefName -Description "NVMe $diskname version built from $vDiskName captured on $TimeStamp" -AdminAddress $DDC
    $script:imageversionnumber = $imageVersion.ImageVersionNumber
    write-host $imageversionnumber
    $sourceImageSpec = Add-ProvImageVersionSpec -ImageDefinitionName $WSImageDefName -ImageVersionNumber $imageversionnumber -HostingUnitName $HVConnectionName -MasterImagePath XDHyp:\HostingUnits\$HVConnectionName\image.folder\$rgName.resourcegroup\$diskname.manageddisk -AdminAddress $DDC
    New-ProvImageVersionSpec -NetworkMapping @{"0" = "XDHyp:\HostingUnits\$HVConnectionName\virtualprivatecloud.folder\$location.region\virtualprivatecloud.folder\$vnetRG.resourcegroup\$vnetName.virtualprivatecloud\$subnetName.network" } -CustomProperties "<CustomProperties xmlns=`"http://schemas.citrix.com/2014/xd/machinecreation`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`"><Property xsi:type=`"StringProperty`" Name=`"LicenseType`" Value=`"Windows_Server`" /></CustomProperties>" -ServiceOffering "XDHyp:\HostingUnits\$HVConnectionName\serviceoffering.folder\$NVMEvmSize.serviceoffering" -SourceImageVersionSpecUid $sourceImageSpec.ImageVersionSpecUid

}
###################################################
# Main Script
###################################################

# Begin Logging
$LogFileTimeStamp = Get-Date -Format "MM-dd-yyyy-HH-mm-tt"
$transcriptPath = Join-Path -Path $PSScriptRoot -ChildPath ".\logs\PVSDiskMigration-$vdiskname-$LogFileTimeStamp.log"
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
        LogFile         = ".\logs\Upload$vdiskName-$LogFileTimeStamp.log"
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

    Start-AlIpsPrepare -ConnectorConfigId (Get-AlConnectorConfig -Name $AlConnectorConfig).Id -ProvisioningType Mcs -SourceDisk $sourcedisk -OutputDiskName $MCSDiskName  -Misa Force -Mcsio Force  -EnableRdp -DebugSettings @{enableBootDiagnostics = $true } | Wait-AlTask | Select-Object -ExpandProperty WorkItems
}
else {
    Write-Host "Disk '$MCSDiskName' already exists in resource group '$rgName'."
    Write-Host "Continuing to NVME Conversion."
}
Write-Progress -Activity "MCS Conversion Done" -Completed
Clear-Host
# Create Managed Image of converted MCS disk
$newDiskId = "/subscriptions/$AzureSubscriptionId/resourceGroups/$rgName/providers/Microsoft.Compute/disks/$MCSDiskName" 

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
$galleryImageReference = @{Id = $latestImageVersion.Id }
$diskConfig = New-AzDiskConfig -Location $location -CreateOption FromImage -GalleryImageReference $galleryImageReference -OsType Windows

New-AzDisk -ResourceGroupName $rgName -DiskName $diskName -Disk $diskConfig

$vm = Get-AzVM -ResourceGroupName $rgName -Name $MPvmname -ErrorAction SilentlyContinue

if ($null -eq $vm) {
}
else {
    Remove-AzureVM -vmName $MPvmname
}
New-AzureVM -vmName $MPvmname -DiskName $diskName -VMSize $NVMEvmSize 

if ($WSImageDefName) {
    New-Image -DiskName $diskName
}

# Images cleanup
If ($imagescleanup -eq $true) {
    If ($diskupdated -eq $true) {
        Write-Host "Removing MCS Managed Disk: $previousDiskName"
        Remove-AzDisk -ResourceGroupName $rgName -DiskName $previousDiskName -Force
    }
    else {
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
# Report Values on Completion
Add-Type -AssemblyName PresentationFramework

if ($WSImageDefName) {


    $message = @"
Image Migration Completed Successfully!

On-Prem vDisk Name: $vDiskName was uploaded to Azure.
This disk was converted and was stored in Citrix Web Studio Image Management as $WSImageDefName and it's version number is $script:imageversionnumber.
"@
}
else {

    $message = @"
On-Prem vDisk Name: $vDiskName was uploaded to Azure.

NVMe Machine Profile for building new Machine Catalogs is named: $MPvmname
NVMe Disk used for building new Machine Catalogs is named: $diskname

Optional SCSI VM settings:
SCSI Machine Profile for building new Machine Catalogs is named: $vmName
SCSI Disk used for building new Machine Catalogs is named: $MCSDiskName
"@
}
[System.Windows.MessageBox]::Show($message, "Script Results")
Stop-Transcript