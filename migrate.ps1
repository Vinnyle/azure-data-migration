<#
.SYNOPSIS
    Azure migration script with an interactive menu.

.DESCRIPTION
    This script migrates Blob containers or Azure File Shares from a source storage account
    to a destination storage account. After entering the connection information (account name,
    access key, and SAS token for each account), a main menu is displayed. The user can choose
    between Blob migration or File Share migration. For each type, a submenu offers options to
    scan the source, scan the destination, or initiate migration.

    For each migration, the following occurs:
      - The script checks if the resource exists on the destination.
      - If not, it prompts the user whether to create it.
          • For Blob containers: it retrieves the source properties (public access and metadata)
            and, if confirmed, creates the container on the destination using the same settings.
          • For File Shares: it retrieves the source properties (quota and metadata)
            and, if confirmed, creates the File Share on the destination using the same settings.
      - It computes an aggregated checksum for the resource on the source, then executes the migration
        via AzCopy (with logs stored in a subfolder of a logs directory), and finally computes an
        aggregated checksum on the destination.
      - The two checksum values are then displayed and compared.
         • For containers: the checksum is based on the concatenation (sorted by blob name) of each blob’s
           MD5 (or, if MD5 is not available, its content length), whose MD5 hash is then computed.
         • For File Shares: the checksum is based on the concatenation (sorted by file name) of each file’s
           size, then computing the MD5 hash of that string.
      - Verification is done by comparing the two checksum values.
      - All AzCopy logs are stored in a “logs” folder under the script’s directory, in subfolders named with
        the resource name and a timestamp.
      - The Ctrl+C warning is displayed with yellow text on a black background.

    **Note:** Yes/no questions accept “yes” or “y” for confirmation and “no” or “n” for denial.
    If AzCopy is not found in the PATH, the script will prompt you for the full path to azcopy.exe.

    Prerequisites:
      - Azure CLI must be installed and available in your PATH.
      - AzCopy is required (or you must provide the path to azcopy.exe).
      - The SAS tokens must be generated with the required permissions.
#>

############################################
# Setup Logging Folder
############################################
$LogRoot = Join-Path $PSScriptRoot "logs"
if (!(Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

############################################
# Helper Functions: Command Checks and Checksum Calculation
############################################
function Check-Command {
    param(
        [Parameter(Mandatory = $true)] [string]$CommandName,
        [Parameter(Mandatory = $true)] [string]$InstallURL
    )
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        Write-Host "`nThe command '$CommandName' was not found in your PATH."
        $response = (Read-Host "Do you want to attempt to install '$CommandName'? (yes/no)").Trim().ToLower()
        if ($response -eq "yes" -or $response -eq "y") {
            Write-Host "Opening the installation page for '$CommandName' in your default browser..."
            Start-Process $InstallURL
            Write-Host "Please install '$CommandName' and then re-run this script."
            exit
        }
        else {
            Write-Host "Cannot proceed without '$CommandName'. Exiting."
            exit
        }
    }
}

function Check-AzCopy {
    if (-not (Get-Command "azcopy" -ErrorAction SilentlyContinue)) {
        Write-Host "`nAzCopy was not found in your PATH."
        $response = (Read-Host "Do you want to provide the full path to azcopy.exe? (yes/no)").Trim().ToLower()
        if ($response -eq "yes" -or $response -eq "y") {
            $userPath = (Read-Host "Please enter the full path to azcopy.exe").Trim()
            if (-not (Test-Path $userPath)) {
                Write-Host "The provided path does not exist. Exiting."
                exit
            }
            return $userPath
        }
        else {
            Write-Host "AzCopy is required. Exiting."
            exit
        }
    }
    else {
        return "azcopy"
    }
}

# --- Check for required commands ---
Check-Command -CommandName "az" -InstallURL "https://aka.ms/installazurecliwindows"
$AzCopyPath = Check-AzCopy

# --- Set up AzCopy log location to the log root (will be overridden per migration) ---
$env:AZCOPY_LOG_LOCATION = $LogRoot

# --- Function to compute an aggregated MD5 checksum for a Blob container ---
function Get-ContainerChecksum {
    param(
        [Parameter(Mandatory = $true)] [string]$containerName,
        [Parameter(Mandatory = $true)] [string]$accountName,
        [Parameter(Mandatory = $true)] [string]$accountKey
    )
    try {
        $blobListJson = az storage blob list --container-name $containerName --account-name $accountName --account-key $accountKey
        $blobList = $blobListJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving blob list for container '$containerName'."
        return $null
    }
    if (-not $blobList) { return "0" }
    $sortedBlobs = $blobList | Sort-Object -Property name
    $combined = ""
    foreach ($blob in $sortedBlobs) {
        if ($blob.contentSettings -and $blob.contentSettings.contentMd5) {
            $combined += $blob.contentSettings.contentMd5
        } else {
            $combined += $blob.properties.contentLength
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hashBytes = $md5.ComputeHash($bytes)
    $hashString = [System.BitConverter]::ToString($hashBytes) -replace "-", ""
    return $hashString
}

# --- Function to compute an aggregated checksum for a File Share (based on file sizes) ---
function Get-FileShareChecksum {
    param(
        [Parameter(Mandatory = $true)] [string]$shareName,
        [Parameter(Mandatory = $true)] [string]$accountName,
        [Parameter(Mandatory = $true)] [string]$accountKey
    )
    try {
        $fileListJson = az storage file list --share-name $shareName --account-name $accountName --account-key $accountKey
        $fileList = $fileListJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving file list for File Share '$shareName'."
        return $null
    }
    if (-not $fileList) { return "0" }
    $sortedFiles = $fileList | Sort-Object -Property name
    $combined = ""
    foreach ($file in $sortedFiles) {
        $combined += $file.properties.contentLength
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hashBytes = $md5.ComputeHash($bytes)
    $hashString = [System.BitConverter]::ToString($hashBytes) -replace "-", ""
    return $hashString
}

############################################
# Menu Functions
############################################
function Get-MainMenuChoice {
    Clear-Host
    Write-Host "=== MAIN MENU ==="
    Write-Host "1. Blob Migration"
    Write-Host "2. File Share Migration"
    Write-Host "3. Quit"
    do {
        $inputStr = (Read-Host "Enter your choice (1-3)").Trim()
        try { $choice = [int]$inputStr } catch { $choice = 0 }
        if ($choice -ge 1 -and $choice -le 3) { return $choice }
        else { Write-Host "Invalid choice. Please enter a number between 1 and 3." }
    } while ($true)
}

function Get-BlobMenuChoice {
    Clear-Host
    Write-Host "=== BLOB MIGRATION MENU ==="
    Write-Host "1. Scan SOURCE"
    Write-Host "2. Scan DESTINATION"
    Write-Host "3. Migrate a container"
    Write-Host "4. Return to Main Menu"
    do {
        $inputStr = (Read-Host "Enter your choice (1-4)").Trim()
        try { $choice = [int]$inputStr } catch { $choice = 0 }
        if ($choice -ge 1 -and $choice -le 4) { return $choice }
        else { Write-Host "Invalid choice. Please enter a number between 1 and 4." }
    } while ($true)
}

function Get-FileShareMenuChoice {
    Clear-Host
    Write-Host "=== FILE SHARE MIGRATION MENU ==="
    Write-Host "1. Scan SOURCE"
    Write-Host "2. Scan DESTINATION"
    Write-Host "3. Migrate a File Share"
    Write-Host "4. Return to Main Menu"
    do {
        $inputStr = (Read-Host "Enter your choice (1-4)").Trim()
        try { $choice = [int]$inputStr } catch { $choice = 0 }
        if ($choice -ge 1 -and $choice -le 4) { return $choice }
        else { Write-Host "Invalid choice. Please enter a number between 1 and 4." }
    } while ($true)
}

############################################
# Scan Functions
############################################
function Scan-BlobLocations {
    Write-Host "`n=== SCAN OF BLOB CONTAINERS (SOURCE) ==="
    try {
        $containersJson = az storage container list --account-name $sourceAccount --account-key $sourceKey --query "[].name"
        $containers = $containersJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving containers from the SOURCE account."
        return
    }
    if ($containers) {
        Write-Host "Containers in the SOURCE account ($sourceAccount):"
        foreach ($c in $containers) { Write-Host " - $c" }
    } else {
        Write-Host "No containers found in the SOURCE account."
    }
}

function Scan-BlobDestinations {
    Write-Host "`n=== SCAN OF BLOB CONTAINERS (DESTINATION) ==="
    try {
        $containersJson = az storage container list --account-name $destinationAccount --account-key $destinationKey --query "[].name"
        $containers = $containersJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving containers from the DESTINATION account."
        return
    }
    if ($containers) {
        Write-Host "Containers in the DESTINATION account ($destinationAccount):"
        foreach ($c in $containers) { Write-Host " - $c" }
    } else {
        Write-Host "No containers found in the DESTINATION account."
    }
}

function Scan-FileShareLocations {
    Write-Host "`n=== SCAN OF FILE SHARES (SOURCE) ==="
    try {
        $sharesJson = az storage share list --account-name $sourceAccount --account-key $sourceKey --query "[].name"
        $shares = $sharesJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving File Shares from the SOURCE account."
        return
    }
    if ($shares) {
        Write-Host "File Shares in the SOURCE account ($sourceAccount):"
        foreach ($s in $shares) { Write-Host " - $s" }
    } else {
        Write-Host "No File Shares found in the SOURCE account."
    }
}

function Scan-FileShareDestinations {
    Write-Host "`n=== SCAN OF FILE SHARES (DESTINATION) ==="
    try {
        $sharesJson = az storage share list --account-name $destinationAccount --account-key $destinationKey --query "[].name"
        $shares = $sharesJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving File Shares from the DESTINATION account."
        return
    }
    if ($shares) {
        Write-Host "File Shares in the DESTINATION account ($destinationAccount):"
        foreach ($s in $shares) { Write-Host " - $s" }
    } else {
        Write-Host "No File Shares found in the DESTINATION account."
    }
}

############################################
# Migration Functions
############################################
function Migrate-BlobContainer {
    param (
        [string]$containerName
    )
    
    # Check existence in the source
    try {
        $srcContainersJson = az storage container list --account-name $sourceAccount --account-key $sourceKey --query "[].name"
        $srcContainers = $srcContainersJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving containers from the SOURCE account."
        return
    }
    if (-not ($srcContainers -contains $containerName)) {
        Write-Host "The container '$containerName' does not exist in the source."
        return
    }
    
    # Check existence in the destination
    try {
        $dstContainersJson = az storage container list --account-name $destinationAccount --account-key $destinationKey --query "[].name"
        $dstContainers = $dstContainersJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving containers from the DESTINATION account."
        return
    }
    if (-not ($dstContainers -contains $containerName)) {
        Write-Host "The container '$containerName' does not exist in the destination."
        $resp = (Read-Host "Do you want to create it? (yes/no)").Trim().ToLower()
        if ($resp -eq "yes" -or $resp -eq "y") {
            # Retrieve source container properties
            try {
                $srcContainerJson = az storage container show --name $containerName --account-name $sourceAccount --account-key $sourceKey
                $srcContainer = $srcContainerJson | ConvertFrom-Json
            } catch {
                Write-Host "Error retrieving properties for container '$containerName' from the SOURCE account."
                return
            }
            # Extract public access and metadata using PSObject.Properties
            $publicAccess = $srcContainer.publicAccess
            $metadataStr = ""
            if ($srcContainer.metadata -and $srcContainer.metadata.PSObject.Properties.Count -gt 0) {
                $metadataStr = ($srcContainer.metadata.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " "
            }
            $createCmd = "az storage container create --name $containerName --account-name $destinationAccount --account-key $destinationKey"
            if ($publicAccess) { $createCmd += " --public-access $publicAccess" }
            if ($metadataStr -ne "") { $createCmd += " --metadata $metadataStr" }
            Write-Host "Creating container '$containerName' in the destination with properties:"
            Write-Host "  Public Access: $publicAccess"
            Write-Host "  Metadata: $metadataStr"
            try {
                Invoke-Expression $createCmd | Out-Null
                Write-Host "Container '$containerName' created in the destination."
            } catch {
                Write-Host "Error creating the container '$containerName' in the destination."
                return
            }
        } else {
            Write-Host "Migration canceled."
            return
        }
    }
    
    # Compute source checksum before migration
    Write-Host "`nComputing source container checksum for '$containerName'..."
    $sourceChecksum = Get-ContainerChecksum -containerName $containerName -accountName $sourceAccount -accountKey $sourceKey
    Write-Host "Source container checksum: $sourceChecksum"
    
    # Create a log folder for this migration: combine container name and timestamp
    $timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
    $logFolderName = "$containerName" + "_" + $timestamp
    $logFolder = Join-Path $LogRoot $logFolderName
    if (!(Test-Path $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    }
    # Set AzCopy log location to this folder
    $env:AZCOPY_LOG_LOCATION = $logFolder
    
    # Build URLs for AzCopy
    $srcUrl = "https://$sourceAccount.blob.core.windows.net/$containerName$sourceSas"
    $dstUrl = "https://$destinationAccount.blob.core.windows.net/$containerName$destinationSas"
    
    Write-Host "`nStarting migration of container '$containerName'..."
    $cmd = "$AzCopyPath copy `"$srcUrl`" `"$dstUrl`" --recursive --check-md5=FailIfDifferent"
    Write-Host "Command: $cmd"
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during migration of container '$containerName'. Code: $LASTEXITCODE"
            return
        }
    } catch {
        Write-Host "Exception during migration: $_"
        return
    }
    Write-Host "Migration completed for container '$containerName'."
    
    # Compute destination checksum after migration
    Write-Host "`nComputing destination container checksum for '$containerName'..."
    $destChecksum = Get-ContainerChecksum -containerName $containerName -accountName $destinationAccount -accountKey $destinationKey
    Write-Host "Destination container checksum: $destChecksum"
    
    Write-Host "`nSUMMARY for container '$containerName':"
    Write-Host "  Source checksum:      $sourceChecksum"
    Write-Host "  Destination checksum: $destChecksum"
    if ($sourceChecksum -eq $destChecksum) {
        Write-Host "Checksum verification successful: The container checksums match."
    } else {
        Write-Host "Checksum verification FAILED: The container checksums do not match."
    }
}

function Migrate-FileShare {
    param (
        [string]$shareName
    )
    
    # Check existence in the source
    try {
        $srcSharesJson = az storage share list --account-name $sourceAccount --account-key $sourceKey --query "[].name"
        $srcShares = $srcSharesJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving File Shares from the SOURCE account."
        return
    }
    if (-not ($srcShares -contains $shareName)) {
        Write-Host "The File Share '$shareName' does not exist in the source."
        return
    }
    
    # Check existence in the destination
    try {
        $dstSharesJson = az storage share list --account-name $destinationAccount --account-key $destinationKey --query "[].name"
        $dstShares = $dstSharesJson | ConvertFrom-Json
    } catch {
        Write-Host "Error retrieving File Shares from the DESTINATION account."
        return
    }
    if (-not ($dstShares -contains $shareName)) {
        Write-Host "The File Share '$shareName' does not exist in the destination."
        $resp = (Read-Host "Do you want to create it? (yes/no)").Trim().ToLower()
        if ($resp -eq "yes" -or $resp -eq "y") {
            # Retrieve source File Share properties
            try {
                $srcShareJson = az storage share show --name $shareName --account-name $sourceAccount --account-key $sourceKey
                $srcShare = $srcShareJson | ConvertFrom-Json
            } catch {
                Write-Host "Error retrieving properties for File Share '$shareName' from the SOURCE account."
                return
            }
            $quota = $srcShare.quota
            $metadataStr = ""
            if ($srcShare.metadata -and $srcShare.metadata.PSObject.Properties.Count -gt 0) {
                $metadataStr = ($srcShare.metadata.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " "
            }
            $createCmd = "az storage share create --name $shareName --account-name $destinationAccount --account-key $destinationKey"
            if ($quota) { $createCmd += " --quota $quota" }
            if ($metadataStr -ne "") { $createCmd += " --metadata $metadataStr" }
            Write-Host "Creating File Share '$shareName' in the destination with properties:"
            Write-Host "  Quota: $quota"
            Write-Host "  Metadata: $metadataStr"
            try {
                Invoke-Expression $createCmd | Out-Null
                Write-Host "File Share '$shareName' created in the destination."
            } catch {
                Write-Host "Error creating the File Share '$shareName'."
                return
            }
        } else {
            Write-Host "Migration canceled."
            return
        }
    }
    
    # Compute source checksum before migration
    Write-Host "`nComputing source File Share checksum for '$shareName'..."
    $sourceChecksum = Get-FileShareChecksum -shareName $shareName -accountName $sourceAccount -accountKey $sourceKey
    Write-Host "Source File Share checksum: $sourceChecksum"
    
    # Create a log folder for this migration: combine share name and timestamp
    $timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
    $logFolderName = "$shareName" + "_" + $timestamp
    $logFolder = Join-Path $LogRoot $logFolderName
    if (!(Test-Path $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    }
    # Set AzCopy log location to this folder
    $env:AZCOPY_LOG_LOCATION = $logFolder
    
    # Build URLs for AzCopy
    $srcUrl = "https://$sourceAccount.file.core.windows.net/$shareName$sourceSas"
    $dstUrl = "https://$destinationAccount.file.core.windows.net/$shareName$destinationSas"
    
    Write-Host "`nStarting migration of File Share '$shareName'..."
    $cmd = "$AzCopyPath copy `"$srcUrl`" `"$dstUrl`" --recursive"
    Write-Host "Command: $cmd"
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during migration of File Share '$shareName'. Code: $LASTEXITCODE"
            return
        }
    } catch {
        Write-Host "Exception during migration: $_"
        return
    }
    Write-Host "Migration completed for File Share '$shareName'."
    
    # Compute destination checksum after migration
    Write-Host "`nComputing destination File Share checksum for '$shareName'..."
    $destChecksum = Get-FileShareChecksum -shareName $shareName -accountName $destinationAccount -accountKey $destinationKey
    Write-Host "Destination File Share checksum: $destChecksum"
    
    Write-Host "`nSUMMARY for File Share '$shareName':"
    Write-Host "  Source checksum:      $sourceChecksum"
    Write-Host "  Destination checksum: $destChecksum"
    if ($sourceChecksum -eq $destChecksum) {
        Write-Host "Checksum verification successful: The File Share checksums match."
    } else {
        Write-Host "Checksum verification FAILED: The File Share checksums do not match."
    }
}

############################################
# Main Menu Loop
############################################
$continueMain = $true
while ($continueMain) {
    $mainChoice = Get-MainMenuChoice
    switch ($mainChoice) {
        1 {
            # Blob Migration
            $continueBlob = $true
            while ($continueBlob) {
                $blobChoice = Get-BlobMenuChoice
                switch ($blobChoice) {
                    1 { Scan-BlobLocations; Pause }
                    2 { Scan-BlobDestinations; Pause }
                    3 { 
                        $containerName = (Read-Host "Enter the name of the container to migrate").Trim()
                        Migrate-BlobContainer -containerName $containerName
                        Pause
                    }
                    4 { $continueBlob = $false }
                }
            }
        }
        2 {
            # File Share Migration
            $continueFS = $true
            while ($continueFS) {
                $fsChoice = Get-FileShareMenuChoice
                switch ($fsChoice) {
                    1 { Scan-FileShareLocations; Pause }
                    2 { Scan-FileShareDestinations; Pause }
                    3 { 
                        $shareName = (Read-Host "Enter the name of the File Share to migrate").Trim()
                        Migrate-FileShare -shareName $shareName
                        Pause
                    }
                    4 { $continueFS = $false }
                }
            }
        }
        3 {
            Write-Host "Goodbye!"
            $continueMain = $false
        }
    }
}