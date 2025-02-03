# Azure Data Migration Script

This repository contains an Azure migration script written in PowerShell. The script is designed to migrate Blob containers and Azure File Shares from one Azure Storage account to another while preserving key properties and verifying data integrity.

## Features

- **Interactive Menu:**  
  The script provides an interactive menu that allows you to choose between Blob migration and File Share migration, with options to scan the source and destination as well as to initiate migration.

- **Resource Existence Check and Manual Creation:**  
  Before migration, the script checks if the target resource (Blob container or File Share) exists in the destination.  
  - If the resource does not exist, the script prompts the user whether to create it manually.
  - If confirmed, it retrieves the resource’s properties from the source and uses them for creation:
    - **For Blob containers:** it retrieves public access settings and metadata.
    - **For File Shares:** it retrieves the quota and metadata.

- **Aggregated Checksum Verification:**  
  The script calculates an aggregated checksum for the resource on both the source and destination:
  - **Blob Containers:**  
    The checksum is computed by sorting the list of blobs by name, concatenating for each blob its MD5 checksum (or its content length if MD5 is not available), and then computing the MD5 hash of the resulting string.
  - **File Shares:**  
    The checksum is computed by sorting the list of files by name, concatenating each file’s size, and then computing the MD5 hash of the resulting string.  
  Both the source and destination checksum values are displayed at the end of the migration and compared to verify data integrity.

- **AzCopy Logging:**  
  All AzCopy logs are stored in a `logs` folder under the script’s directory.  
  For each migration, a subfolder is created with a name that combines the resource name and a timestamp (format `yyyyMMdd_HHmmss`).  
  The environment variable `AZCOPY_LOG_LOCATION` is set accordingly so that AzCopy writes its log files in the appropriate folder.

- **Enhanced Ctrl+C Handling:**  
  The script intercepts the Ctrl+C (interrupt) signal and prompts the user for confirmation before quitting.  
  The warning message is displayed with yellow text on a black background.

- **Dependency Checks:**  
  The script checks whether the Azure CLI (`az`) and AzCopy are available in your PATH.  
  If AzCopy is not found, the user is prompted to provide the full path to `azcopy.exe`.

## Prerequisites

- **Azure CLI:**  
  Must be installed and available in your PATH.  
  [Install Azure CLI](https://aka.ms/installazurecliwindows)

- **AzCopy:**  
  Must be installed and available in your PATH, or you must provide the full path when prompted.  
  [Download AzCopy](https://aka.ms/downloadazcopy-v10-windows)

- **PowerShell:**  
  The script is written in PowerShell and should be run in an interactive session (e.g., Windows PowerShell or PowerShell Core).

- **SAS Tokens:**  
  Ensure that the SAS tokens for both the source and destination storage accounts have the required permissions.

## Usage

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/azure-data-migration.git
