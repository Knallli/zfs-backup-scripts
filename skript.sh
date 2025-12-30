#!/bin/bash

# --- KONFIGURATION ---
ENABLE_DRY_RUN=false 

# Haupt-Datasets und ihre Ziel-Basispfade
declare -A BACKUP_JOBS
BACKUP_JOBS=(
    ["cache/main"]="/mnt/user/backup/zfs-test/main"
    ["cache/appdata"]="/mnt/user/backup/zfs-test/appdata"
    ["cache/domains"]="/mnt/user/backup/zfs-test/domains"
    ["cache/lxc"]="/mnt/user/backup/zfs-test/lxc"
)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SNAP_NAME="rsync_full_$TIMESTAMP"

# --- LOGIK ---

for PARENT_DATASET in "${!BACKUP_JOBS[@]}"; do
    TARGET_BASE="${BACKUP_JOBS[$PARENT_DATASET]}"
    
    echo "====================================================================="
    echo "VERARBEITE PARENT: $PARENT_DATASET"
    
    # 1. Alle Child-Datasets finden (inklusive dem Parent selbst)
    # Wir sortieren sie, damit der Parent zuerst kommt
    DATASETS=$(zfs list -H -o name -r "$PARENT_DATASET")

    # 2. Rekursiven Snapshot für den ganzen Baum erstellen
    if [ "$ENABLE_DRY_RUN" = false ]; then
        echo "  [EXEC] Erstelle rekursiven Snapshot für $PARENT_DATASET Baum..."
        zfs snapshot -r "$PARENT_DATASET@$SNAP_NAME"
    else
        echo "  [DRY] Würde snapshot -r $PARENT_DATASET@$SNAP_NAME ausführen"
    fi

    # 3. Jedes Dataset einzeln per rsync übertragen
    for DS in $DATASETS; do
        # Mountpoint des aktuellen (Sub-)Datasets ermitteln
        DS_MOUNT=$(zfs get -H -o value mountpoint "$DS")
        
        # Relativen Pfad zum Parent berechnen, um die Struktur im Ziel nachzubilden
        # Beispiel: Parent=cache/main, DS=cache/main/docker/vol1 -> REL_PATH=docker/vol1
        REL_PATH=${DS#$PARENT_DATASET}
        REL_PATH=${REL_PATH#/} # Führenden Slash entfernen falls vorhanden
        
        # Zielordner für dieses spezifische Dataset
        CURRENT_TARGET="$TARGET_BASE/$REL_PATH"
        SNAP_PATH="$DS_MOUNT/.zfs/snapshot/$SNAP_NAME"

        echo "  -> Sync: $DS"
        
        if [ "$ENABLE_DRY_RUN" = false ]; then
            mkdir -p "$CURRENT_TARGET"
            # rsync ausführen
            # Wir nutzen hier NICHT --delete auf Parent-Ebene für die Subs, 
            # da rsync sonst die anderen Sub-Ordner löschen würde.
            rsync -avh --delete "$SNAP_PATH/" "$CURRENT_TARGET/"
        else
            echo "    [DRY] rsync -avh --delete $SNAP_PATH/ $CURRENT_TARGET/"
        fi
    done

    # 4. Cleanup: Alle Snapshots im Baum löschen
    if [ "$ENABLE_DRY_RUN" = false ]; then
        echo "  [EXEC] Lösche rekursiven Snapshot Baum..."
        zfs destroy -r "$PARENT_DATASET@$SNAP_NAME"
    fi
done

echo "====================================================================="
echo "Backup-Lauf beendet."
