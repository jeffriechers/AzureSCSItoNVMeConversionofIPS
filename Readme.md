## Citrix Image Portability Services with Azure NVMe conversion
These scripts are specifically for the Citrix Azure Image Portability Service.  But they can be co-opted for converting any v5 and earlier SCSI based Azure VM to v6 and v7 NVMe skus as needed.

### Cloud Based Image Portability
CloudIPS.ps1 is a script that is run after using the existing Citrix IPS engine that is cloud hosted.  Modify the ps1 script to point it to your resources, and it will take an MCS prepared IPS image and convert it to an NVMe supported image for v6 and v7 Azure skus.

### On-Premise Based Image Portability
The 2511 version of Citrix App Layering brings the cloud based version of IPS to your local datacenter.  Ensure where you are running this image from has line of site to the Azure Resource Location before running.  Ensure you have your Azure Resource Location setup in the App Layering software for proper conversion.  Just call OnPremIPS.ps1 nameofpvsdisk.vhdx and it will send it to Azure, convert it to MCS, and then capture it for a v6 and v7 Azure SKU.

This version has been built on the 2511 Early Access Release code.  And may need modification once the final App Layering 2511 version is released.

### Azure Image Gallery Cleanup
AzureImageGalleryCleanup.ps1 provides an easy method to clean up previously converted NVMe images, reducing your Azure spend.