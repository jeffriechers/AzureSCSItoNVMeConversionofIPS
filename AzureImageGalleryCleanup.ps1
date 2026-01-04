# Requires Az PowerShell module

# Variables
# Azure Connection Variables
$AzureClientId = "" # Citrix SPN that has permissions on subscription for Citrix Administration
$AzureClientSecret = "" # Secret for SPN
$AzureTenantId = "" # Tenant ID for Azure AD
$galleryName      = "" #Azure Shared Image Gallery name
$imageDefName     = "" #Azure Shared Image Definition name
$rgName      = "" # Resource Group name

# Connect to Azure
$SecureStringPwd = $AzureClientSecret | ConvertTo-SecureString -AsPlainText -Force
$pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AzureClientId, $SecureStringPwd
Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $AzureTenantId -Subscription $AzureSubscriptionId

#Get all image versions
$imageVersions = Get-AzGalleryImageVersion `
    -ResourceGroupName $rgName `
    -GalleryName $galleryName `
    -GalleryImageDefinitionName $imageDefName

if (-not $imageVersions) {
    Write-Host "No image versions found for definition '$imageDefName' in gallery '$galleryName'."
    exit
}

#Display numbered list
Write-Host "Available image versions:"
for ($i = 0; $i -lt $imageVersions.Count; $i++) {
    Write-Host "[$i] $($imageVersions[$i].Name)"
}

#Prompt user
Write-Host "Enter the number(s) of the image version(s) to delete (comma-separated), or type ALL to delete all."
$selection = Read-Host "Your choice"

#Determine selection
if ($selection -eq "ALL") {
    $selectedVersions = $imageVersions
}
else {
    $indices = $selection -split "," | ForEach-Object { $_.Trim() }
    $selectedVersions = foreach ($index in $indices) {
        if ($index -match '^\d+$' -and [int]$index -lt $imageVersions.Count) {
            $imageVersions[[int]$index]
        }
        else {
            Write-Host "Invalid selection: $index"
        }
    }
}

#Delete selected versions
foreach ($version in $selectedVersions) {
    Write-Host "Deleting image version '$($version.Name)'..."
    Remove-AzGalleryImageVersion `
        -ResourceGroupName $rgName `
        -GalleryName $galleryName `
        -GalleryImageDefinitionName $imageDefName `
        -Name $version.Name -Force
    Write-Host "Deleted '$($version.Name)'."
}