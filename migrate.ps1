<#
.SYNOPSIS
    Script interactif de migration des donn�es entre comptes de stockage Azure.

.DESCRIPTION
    Ce script permet de migrer des containers Blob ou des Azure File Shares d'un compte source vers un compte destination en utilisant AzCopy.
    Il offre une interface interactive pour saisir les informations de connexion, lister les containers ou File Shares existants,
    et effectuer la migration avec plusieurs v�rifications (code de retour, int�grit� MD5 pour les blobs, comparaison du nombre d'objets transf�r�s).

.PARAMETER migrationType
    Type de migration � effectuer : 'blob' pour les containers Blob ou 'fileshare' pour les Azure File Shares.

.NOTES
    - Pr�requis : Azure CLI et AzCopy install�s.
    - La v�rification MD5 est appliqu�e pour la migration des containers Blob.
    - Ce script est con�u pour �tre simple � utiliser et peut �tre adapt� selon vos besoins.
#>

# Demander le type de migration souhait�
$migrationType = Read-Host "Quel type de migration souhaitez-vous effectuer ? Tapez 'blob' pour migrer des containers Blob ou 'fileshare' pour migrer des Azure File Shares"

# Demander les informations de connexion pour le compte SOURCE et le compte DESTINATION
$sourceAccount = Read-Host "Entrez le nom du compte de stockage SOURCE"
$sourceKey     = Read-Host "Entrez la cl� d'acc�s du compte SOURCE"
$sourceSas     = Read-Host "Entrez le SAS token du compte SOURCE (commencez par '?' par exemple)"

$destinationAccount = Read-Host "Entrez le nom du compte de stockage DESTINATION"
$destinationKey     = Read-Host "Entrez la cl� d'acc�s du compte DESTINATION"
$destinationSas     = Read-Host "Entrez le SAS token du compte DESTINATION (commencez par '?' par exemple)"

if ($migrationType -eq "blob") {

    Write-Output "`nMigration de containers Blob"

    while ($true) {

        Write-Output "`n-------------------------------"
        Write-Output "Liste des containers du compte SOURCE ($sourceAccount) :"
        try {
            $sourceContainers = az storage container list --account-name $sourceAccount --account-key $sourceKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la r�cup�ration des containers du compte SOURCE."
            break
        }
        if (-not $sourceContainers) {
            Write-Output "Aucun container trouv� dans le compte SOURCE."
            break
        }
        $sourceContainers | ForEach-Object { Write-Output " - $_" }

        Write-Output "`nListe des containers du compte DESTINATION ($destinationAccount) :"
        try {
            $destinationContainers = az storage container list --account-name $destinationAccount --account-key $destinationKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la r�cup�ration des containers du compte DESTINATION."
            break
        }
        if ($destinationContainers) {
            $destinationContainers | ForEach-Object { Write-Output " - $_" }
        }
        else {
            Write-Output "Aucun container trouv� dans le compte DESTINATION."
        }

        # S�lection du container � migrer
        $containerToCopy = Read-Host "`nEntrez le nom du container � migrer depuis le compte SOURCE (ou tapez 'exit' pour quitter)"
        if ($containerToCopy -eq "exit") {
            Write-Output "Fin du script."
            break
        }
        if (-not ($sourceContainers -contains $containerToCopy)) {
            Write-Output "Le container '$containerToCopy' n'existe pas dans le compte SOURCE. Veuillez r�essayer."
            continue
        }

        # V�rifier l'existence du container dans le compte DESTINATION
        if (-not ($destinationContainers -contains $containerToCopy)) {
            $createResponse = Read-Host "Le container '$containerToCopy' n'existe pas dans le compte DESTINATION. Voulez-vous le cr�er automatiquement ? (oui/non)"
            if ($createResponse -eq "oui") {
                Write-Output "Cr�ation du container '$containerToCopy' dans le compte DESTINATION..."
                try {
                    az storage container create --name $containerToCopy --account-name $destinationAccount --account-key $destinationKey | Out-Null
                    Write-Output "Container '$containerToCopy' cr��."
                }
                catch {
                    Write-Output "Erreur lors de la cr�ation du container '$containerToCopy'."
                    continue
                }
            }
            else {
                Write-Output "Migration annul�e pour ce container. Veuillez choisir un autre container."
                continue
            }
        }
        else {
            Write-Output "Le container '$containerToCopy' existe d�j� dans le compte DESTINATION."
        }

        # Construction des URLs pour AzCopy avec v�rification MD5
        $sourceUrl      = "https://$sourceAccount.blob.core.windows.net/$containerToCopy$sourceSas"
        $destinationUrl = "https://$destinationAccount.blob.core.windows.net/$containerToCopy$destinationSas"

        Write-Output "`nD�marrage de la copie du container '$containerToCopy'..."
        $azCopyCommand = "azcopy copy `"$sourceUrl`" `"$destinationUrl`" --recursive --check-md5=FailIfDifferent"
        Write-Output "Ex�cution de la commande :"
        Write-Output $azCopyCommand

        try {
            Invoke-Expression $azCopyCommand
            if ($LASTEXITCODE -ne 0) {
                Write-Output "Erreur lors de la copie du container '$containerToCopy'. Code de retour: $LASTEXITCODE"
                continue
            }
        }
        catch {
            Write-Output "Exception lors de l'ex�cution de la commande AzCopy: $_"
            continue
        }

        Write-Output "La copie du container '$containerToCopy' est termin�e."

        # V�rification du nombre de blobs transf�r�s
        try {
            $sourceCount = az storage blob list --container-name $containerToCopy --account-name $sourceAccount --account-key $sourceKey --query "length([])" -o tsv
            $destinationCount = az storage blob list --container-name $containerToCopy --account-name $destinationAccount --account-key $destinationKey --query "length([])" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la v�rification des blobs transf�r�s."
            continue
        }
        Write-Output "Nombre de blobs dans le container SOURCE: $sourceCount"
        Write-Output "Nombre de blobs dans le container DESTINATION: $destinationCount"
        if ($sourceCount -ne $destinationCount) {
            Write-Output "Attention : le nombre de blobs transf�r�s ne correspond pas entre la source et la destination."
        }
        else {
            Write-Output "V�rification r�ussie : le nombre de blobs correspond."
        }

        # Demander si l'utilisateur souhaite migrer un autre container Blob
        $continueResponse = Read-Host "`nVoulez-vous migrer un autre container Blob ? (oui/non)"
        if ($continueResponse -ne "oui") {
            Write-Output "Fin du script de migration de containers Blob."
            break
        }
    }
}
elseif ($migrationType -eq "fileshare") {

    Write-Output "`nMigration d'Azure File Shares"

    while ($true) {

        Write-Output "`n-------------------------------"
        Write-Output "Liste des File Shares du compte SOURCE ($sourceAccount) :"
        try {
            $sourceShares = az storage share list --account-name $sourceAccount --account-key $sourceKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la r�cup�ration des File Shares du compte SOURCE."
            break
        }
        if (-not $sourceShares) {
            Write-Output "Aucun File Share trouv� dans le compte SOURCE."
            break
        }
        $sourceShares | ForEach-Object { Write-Output " - $_" }

        Write-Output "`nListe des File Shares du compte DESTINATION ($destinationAccount) :"
        try {
            $destinationShares = az storage share list --account-name $destinationAccount --account-key $destinationKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la r�cup�ration des File Shares du compte DESTINATION."
            break
        }
        if ($destinationShares) {
            $destinationShares | ForEach-Object { Write-Output " - $_" }
        }
        else {
            Write-Output "Aucun File Share trouv� dans le compte DESTINATION."
        }

        # S�lection du File Share � migrer
        $shareToCopy = Read-Host "`nEntrez le nom du File Share � migrer depuis le compte SOURCE (ou tapez 'exit' pour quitter)"
        if ($shareToCopy -eq "exit") {
            Write-Output "Fin du script."
            break
        }
        if (-not ($sourceShares -contains $shareToCopy)) {
            Write-Output "Le File Share '$shareToCopy' n'existe pas dans le compte SOURCE. Veuillez r�essayer."
            continue
        }

        # V�rifier l'existence du File Share dans le compte DESTINATION
        if (-not ($destinationShares -contains $shareToCopy)) {
            $createResponse = Read-Host "Le File Share '$shareToCopy' n'existe pas dans le compte DESTINATION. Voulez-vous le cr�er automatiquement ? (oui/non)"
            if ($createResponse -eq "oui") {
                Write-Output "Cr�ation du File Share '$shareToCopy' dans le compte DESTINATION..."
                try {
                    az storage share create --name $shareToCopy --account-name $destinationAccount --account-key $destinationKey | Out-Null
                    Write-Output "File Share '$shareToCopy' cr��."
                }
                catch {
                    Write-Output "Erreur lors de la cr�ation du File Share '$shareToCopy'."
                    continue
                }
            }
            else {
                Write-Output "Migration annul�e pour ce File Share. Veuillez choisir un autre File Share."
                continue
            }
        }
        else {
            Write-Output "Le File Share '$shareToCopy' existe d�j� dans le compte DESTINATION."
        }

        # Construction des URLs pour AzCopy pour les File Shares
        $sourceUrl      = "https://$sourceAccount.file.core.windows.net/$shareToCopy$sourceSas"
        $destinationUrl = "https://$destinationAccount.file.core.windows.net/$shareToCopy$destinationSas"

        Write-Output "`nD�marrage de la copie du File Share '$shareToCopy'..."
        $azCopyCommand = "azcopy copy `"$sourceUrl`" `"$destinationUrl`" --recursive"
        Write-Output "Ex�cution de la commande :"
        Write-Output $azCopyCommand

        try {
            Invoke-Expression $azCopyCommand
            if ($LASTEXITCODE -ne 0) {
                Write-Output "Erreur lors de la copie du File Share '$shareToCopy'. Code de retour: $LASTEXITCODE"
                continue
            }
        }
        catch {
            Write-Output "Exception lors de l'ex�cution de la commande AzCopy: $_"
            continue
        }

        Write-Output "La copie du File Share '$shareToCopy' est termin�e."

        # V�rification du nombre de fichiers transf�r�s
        try {
            $sourceCount = az storage file list --share-name $shareToCopy --account-name $sourceAccount --account-key $sourceKey --query "length([])" -o tsv
            $destinationCount = az storage file list --share-name $shareToCopy --account-name $destinationAccount --account-key $destinationKey --query "length([])" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la v�rification des fichiers transf�r�s."
            continue
        }
        Write-Output "Nombre de fichiers dans le File Share SOURCE: $sourceCount"
        Write-Output "Nombre de fichiers dans le File Share DESTINATION: $destinationCount"
        if ($sourceCount -ne $destinationCount) {
            Write-Output "Attention : le nombre de fichiers transf�r�s ne correspond pas entre la source et la destination."
        }
        else {
            Write-Output "V�rification r�ussie : le nombre de fichiers correspond."
        }

        # Demander si l'utilisateur souhaite migrer un autre File Share
        $continueResponse = Read-Host "`nVoulez-vous migrer un autre File Share ? (oui/non)"
        if ($continueResponse -ne "oui") {
            Write-Output "Fin du script de migration des File Shares."
            break
        }
    }
}
else {
    Write-Output "Type de migration non reconnu. Veuillez ex�cuter le script en sp�cifiant 'blob' ou 'fileshare'."
}
