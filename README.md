# Azure Data Migration Script

Ce dépôt contient un script PowerShell interactif pour migrer des données entre des comptes de stockage Azure.  
Le script permet de migrer soit des **containers Blob**, soit des **Azure File Shares** à l'aide d'AzCopy, avec plusieurs vérifications (code de retour, comparaison du nombre d'objets, option MD5 pour les blobs, etc.) pour assurer l'intégrité du transfert.

## Fonctionnalités

- Migration interactive avec saisie des informations (noms de comptes, clés, SAS tokens).
- Choix du type de migration : **Blob** ou **File Share**.
- Vérification et création automatique (si nécessaire) du container ou du File Share dans le compte de destination.
- Vérification de l'intégrité via `--check-md5=FailIfDifferent` pour les blobs.
- Comparaison du nombre d'objets transférés (blobs ou fichiers) entre la source et la destination.
- Gestion des erreurs et affichage de messages clairs pour faciliter le dépannage.

## Prérequis

- [Azure CLI](https://docs.microsoft.com/fr-fr/cli/azure/install-azure-cli) installé et configuré.
- [AzCopy](https://docs.microsoft.com/fr-fr/azure/storage/common/storage-use-azcopy-v10) installé et accessible dans le PATH.
- PowerShell (version 5 ou supérieure).

## Utilisation

1. Clonez ce dépôt :

   ```bash
   git clone https://github.com/votre-utilisateur/azure-data-migration.git