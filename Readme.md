## Citrix Image Portability Services with Azure NVMe conversion
These scripts are specifically for the Citrix Azure Image Portability Service.  But they can be co-opted for converting any v5 and earlier SCSI based Azure VM to v6 and v7 NVMe skus as needed.

### On-Premise Based Image Portability
The 2511 version of Citrix App Layering brings the cloud based version of IPS to your local datacenter.  To use this entirely from on-premise make sure you meet the following requirements.

* Ensure the machine where you are running this script from has line of site to the Azure Resource Location before running.  
* To use Web Studio Image Galleries, only VDAs with 2402 (any version) and 2507 (vanilla only) are supported at this time.
* Your Delivery Controller, or Domain Joined machine requires the follow pre-requisites
* Azure PowerShell Module installed
* Citrix PoshSDK Module installed if not running on Delivery Controller
* Appropriate permissions in Azure for creating resources via Service Principal
* Read Only Access to the on-prem PVS vDisk share
* An on-prem Citrix App Layering Appliance 2511+ configured with an Azure Connector for IPS
* Credentials on the Citrix App Layering Appliance to use the IPS functions
* Citrix.Applayering Powershell Module installed "Install-Module -Name "Citrix.AppLayering" -Scope CurrentUser"
* Citrix.Image.Uploader PowerShell Module installed "Install-Module -Name "Citrix.Image.Uploader" -Scope CurrentUser"


Modify the variables in the script to match your environment before running.
* PVS Variables
```
$SrcSmbHostandSharePath = "" # Path to PVS vDisk Share \\server\share
```
* Azure Connection Variables
```
$AzureClientId = "" # Citrix SPN that has permissions on subscription for Citrix Administration
$AzureClientSecret = "" # Secret for SPN
$AzureSubscriptionId = "" # Subscription where resources will be created
$AzureTenantId = "" # Tenant ID for Azure AD
```
* Azure Build VMs Variables
```
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
```
* Azure Shared Image Gallery Variables
```
$galleryName = "SharedImageGallery_$rgName" # Name of the Shared Image Gallery used for NVMe Images, will also be re-used for Citrix Web Studio Image Management
$imageDefName = "v6Convert" # Name of the Shared Image Definition used for converting NVMe Images
$publisher = "Citrix" # Publisher Name for Shared Image Gallery details
$offer = "IPS" # Offer Name for Shared Image Gallery details
$sku = "MCS" # SKU Name for Shared Image Gallery details
```
* IPS Appliance Variables
```
$ALApplianceAddress = "" # Address of the on-prem IPS Appliance, IP or FQDN
$ALport = "443" # Port of the on-prem IPS Appliance (Script already is set to accept self-signed certs)
$AlConnectorConfig = "" # Name of the Connector Config in the IPS Appliance for Azure (Ensure it is setup for Azure IPS, and not for Azure App Layering)
$imagescleanup = $true # Set to $true to cleanup managed disks and images after Shared Image Gallery captures (recommended).  Set to $false to retain all intermediate disks and images during testing runs.  Will incur ongoing charges if not removed, and you will be notified of this in the logs.
```
* Web Studio Image Management Settings
```
$DDC = "" # On-Prem Delivery Controller FQDN for placing NVMe Images into Web Studio Image Management (Requires VDA 2402 - any CU, or 2507 vanilla ONLY at this point 2507 CU1 and 2511 VDA are not supported at this time.)
$HVConnectionName = "" # Azure Hypervisor Connection Name as seen in Studio, this is the name under the Microsoft Azure TM Hosting Connection.  If you specify the Microsoft Azure TM Hosting Connection this will fail.
$WSImageDefName = "" # Name of the Image Definition as it will appear in Web Studio Image Management, and in the Azure Shared Image Gallery.
$OSType = "Windows" # Possible values: "Windows" or "Linux"
$SessionType = "MultiSession" # Possible values: "SingleSession" or "MultiSession"
$UseSharedImageGallery = $true # Variable to indicate use of Shared Image Gallery in Web Studio Image Management, $true is the only supported option at this point.  Future Scripts will allow modifying this to use dedicated Galleries
```

Once you have all the pre-requisites and variables set in the PowerShell script, you can execute it with the following command.
```
.\OnPremIPS.ps1 -vDiskName "Win10-22H2x64.vhdx"
```

### Azure Image Gallery Cleanup
AzureImageGalleryCleanup.ps1 provides an easy method to clean up previously converted NVMe images, reducing your Azure spend.
