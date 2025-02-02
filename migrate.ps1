<#
.SYNOPSIS
    Script interactif de migration des données entre comptes de stockage Azure.

.DESCRIPTION
    Ce script permet de migrer des containers Blob ou des Azure File Shares d'un compte source vers un compte destination en utilisant AzCopy.
    Il offre une interface interactive pour saisir les informations de connexion, lister les containers ou File Shares existants,
    et effectuer la migration avec plusieurs vérifications (code de retour, intégrité MD5 pour les blobs, comparaison du nombre d'objets transférés).

.PARAMETER migrationType
    Type de migration à effectuer : 'blob' pour les containers Blob ou 'fileshare' pour les Azure File Shares.

.NOTES
    - Prérequis : Azure CLI et AzCopy installés.
    - La vérification MD5 est appliquée pour la migration des containers Blob.
    - Ce script est conçu pour être simple à utiliser et peut être adapté selon vos besoins.
#>

# Demander le type de migration souhaité
$migrationType = Read-Host "Quel type de migration souhaitez-vous effectuer ? Tapez 'blob' pour migrer des containers Blob ou 'fileshare' pour migrer des Azure File Shares"

# Demander les informations de connexion pour le compte SOURCE et le compte DESTINATION
$sourceAccount = Read-Host "Entrez le nom du compte de stockage SOURCE"
$sourceKey     = Read-Host "Entrez la clé d'accès du compte SOURCE"
$sourceSas     = Read-Host "Entrez le SAS token du compte SOURCE (commencez par '?' par exemple)"

$destinationAccount = Read-Host "Entrez le nom du compte de stockage DESTINATION"
$destinationKey     = Read-Host "Entrez la clé d'accès du compte DESTINATION"
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
            Write-Output "Erreur lors de la récupération des containers du compte SOURCE."
            break
        }
        if (-not $sourceContainers) {
            Write-Output "Aucun container trouvé dans le compte SOURCE."
            break
        }
        $sourceContainers | ForEach-Object { Write-Output " - $_" }

        Write-Output "`nListe des containers du compte DESTINATION ($destinationAccount) :"
        try {
            $destinationContainers = az storage container list --account-name $destinationAccount --account-key $destinationKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la récupération des containers du compte DESTINATION."
            break
        }
        if ($destinationContainers) {
            $destinationContainers | ForEach-Object { Write-Output " - $_" }
        }
        else {
            Write-Output "Aucun container trouvé dans le compte DESTINATION."
        }

        # Sélection du container à migrer
        $containerToCopy = Read-Host "`nEntrez le nom du container à migrer depuis le compte SOURCE (ou tapez 'exit' pour quitter)"
        if ($containerToCopy -eq "exit") {
            Write-Output "Fin du script."
            break
        }
        if (-not ($sourceContainers -contains $containerToCopy)) {
            Write-Output "Le container '$containerToCopy' n'existe pas dans le compte SOURCE. Veuillez réessayer."
            continue
        }

        # Vérifier l'existence du container dans le compte DESTINATION
        if (-not ($destinationContainers -contains $containerToCopy)) {
            $createResponse = Read-Host "Le container '$containerToCopy' n'existe pas dans le compte DESTINATION. Voulez-vous le créer automatiquement ? (oui/non)"
            if ($createResponse -eq "oui") {
                Write-Output "Création du container '$containerToCopy' dans le compte DESTINATION..."
                try {
                    az storage container create --name $containerToCopy --account-name $destinationAccount --account-key $destinationKey | Out-Null
                    Write-Output "Container '$containerToCopy' créé."
                }
                catch {
                    Write-Output "Erreur lors de la création du container '$containerToCopy'."
                    continue
                }
            }
            else {
                Write-Output "Migration annulée pour ce container. Veuillez choisir un autre container."
                continue
            }
        }
        else {
            Write-Output "Le container '$containerToCopy' existe déjà dans le compte DESTINATION."
        }

        # Construction des URLs pour AzCopy avec vérification MD5
        $sourceUrl      = "https://$sourceAccount.blob.core.windows.net/$containerToCopy$sourceSas"
        $destinationUrl = "https://$destinationAccount.blob.core.windows.net/$containerToCopy$destinationSas"

        Write-Output "`nDémarrage de la copie du container '$containerToCopy'..."
        $azCopyCommand = "azcopy copy `"$sourceUrl`" `"$destinationUrl`" --recursive --check-md5=FailIfDifferent"
        Write-Output "Exécution de la commande :"
        Write-Output $azCopyCommand

        try {
            Invoke-Expression $azCopyCommand
            if ($LASTEXITCODE -ne 0) {
                Write-Output "Erreur lors de la copie du container '$containerToCopy'. Code de retour: $LASTEXITCODE"
                continue
            }
        }
        catch {
            Write-Output "Exception lors de l'exécution de la commande AzCopy: $_"
            continue
        }

        Write-Output "La copie du container '$containerToCopy' est terminée."

        # Vérification du nombre de blobs transférés
        try {
            $sourceCount = az storage blob list --container-name $containerToCopy --account-name $sourceAccount --account-key $sourceKey --query "length([])" -o tsv
            $destinationCount = az storage blob list --container-name $containerToCopy --account-name $destinationAccount --account-key $destinationKey --query "length([])" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la vérification des blobs transférés."
            continue
        }
        Write-Output "Nombre de blobs dans le container SOURCE: $sourceCount"
        Write-Output "Nombre de blobs dans le container DESTINATION: $destinationCount"
        if ($sourceCount -ne $destinationCount) {
            Write-Output "Attention : le nombre de blobs transférés ne correspond pas entre la source et la destination."
        }
        else {
            Write-Output "Vérification réussie : le nombre de blobs correspond."
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
            Write-Output "Erreur lors de la récupération des File Shares du compte SOURCE."
            break
        }
        if (-not $sourceShares) {
            Write-Output "Aucun File Share trouvé dans le compte SOURCE."
            break
        }
        $sourceShares | ForEach-Object { Write-Output " - $_" }

        Write-Output "`nListe des File Shares du compte DESTINATION ($destinationAccount) :"
        try {
            $destinationShares = az storage share list --account-name $destinationAccount --account-key $destinationKey --query "[].name" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la récupération des File Shares du compte DESTINATION."
            break
        }
        if ($destinationShares) {
            $destinationShares | ForEach-Object { Write-Output " - $_" }
        }
        else {
            Write-Output "Aucun File Share trouvé dans le compte DESTINATION."
        }

        # Sélection du File Share à migrer
        $shareToCopy = Read-Host "`nEntrez le nom du File Share à migrer depuis le compte SOURCE (ou tapez 'exit' pour quitter)"
        if ($shareToCopy -eq "exit") {
            Write-Output "Fin du script."
            break
        }
        if (-not ($sourceShares -contains $shareToCopy)) {
            Write-Output "Le File Share '$shareToCopy' n'existe pas dans le compte SOURCE. Veuillez réessayer."
            continue
        }

        # Vérifier l'existence du File Share dans le compte DESTINATION
        if (-not ($destinationShares -contains $shareToCopy)) {
            $createResponse = Read-Host "Le File Share '$shareToCopy' n'existe pas dans le compte DESTINATION. Voulez-vous le créer automatiquement ? (oui/non)"
            if ($createResponse -eq "oui") {
                Write-Output "Création du File Share '$shareToCopy' dans le compte DESTINATION..."
                try {
                    az storage share create --name $shareToCopy --account-name $destinationAccount --account-key $destinationKey | Out-Null
                    Write-Output "File Share '$shareToCopy' créé."
                }
                catch {
                    Write-Output "Erreur lors de la création du File Share '$shareToCopy'."
                    continue
                }
            }
            else {
                Write-Output "Migration annulée pour ce File Share. Veuillez choisir un autre File Share."
                continue
            }
        }
        else {
            Write-Output "Le File Share '$shareToCopy' existe déjà dans le compte DESTINATION."
        }

        # Construction des URLs pour AzCopy pour les File Shares
        $sourceUrl      = "https://$sourceAccount.file.core.windows.net/$shareToCopy$sourceSas"
        $destinationUrl = "https://$destinationAccount.file.core.windows.net/$shareToCopy$destinationSas"

        Write-Output "`nDémarrage de la copie du File Share '$shareToCopy'..."
        $azCopyCommand = "azcopy copy `"$sourceUrl`" `"$destinationUrl`" --recursive"
        Write-Output "Exécution de la commande :"
        Write-Output $azCopyCommand

        try {
            Invoke-Expression $azCopyCommand
            if ($LASTEXITCODE -ne 0) {
                Write-Output "Erreur lors de la copie du File Share '$shareToCopy'. Code de retour: $LASTEXITCODE"
                continue
            }
        }
        catch {
            Write-Output "Exception lors de l'exécution de la commande AzCopy: $_"
            continue
        }

        Write-Output "La copie du File Share '$shareToCopy' est terminée."

        # Vérification du nombre de fichiers transférés
        try {
            $sourceCount = az storage file list --share-name $shareToCopy --account-name $sourceAccount --account-key $sourceKey --query "length([])" -o tsv
            $destinationCount = az storage file list --share-name $shareToCopy --account-name $destinationAccount --account-key $destinationKey --query "length([])" -o tsv
        }
        catch {
            Write-Output "Erreur lors de la vérification des fichiers transférés."
            continue
        }
        Write-Output "Nombre de fichiers dans le File Share SOURCE: $sourceCount"
        Write-Output "Nombre de fichiers dans le File Share DESTINATION: $destinationCount"
        if ($sourceCount -ne $destinationCount) {
            Write-Output "Attention : le nombre de fichiers transférés ne correspond pas entre la source et la destination."
        }
        else {
            Write-Output "Vérification réussie : le nombre de fichiers correspond."
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
    Write-Output "Type de migration non reconnu. Veuillez exécuter le script en spécifiant 'blob' ou 'fileshare'."
}
