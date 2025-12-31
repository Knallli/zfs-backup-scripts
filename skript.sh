#!/bin/bash

# --- CONFIGURATION ---
ENABLE_DRY_RUN=false

declare -A BACKUP_JOBS
BACKUP_JOBS=(
    ["cache/main"]="/mnt/user/backup/zfs-test/main"
    ["cache/appdata"]="/mnt/user/backup/zfs-test/appdata"
    ["cache/domains"]="/mnt/user/backup/zfs-test/domains"
    ["cache/lxc"]="/mnt/user/backup/zfs-test/lxc"
)

SNAP_PREFIX="rsync_auto"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NEW_SNAP_NAME="${SNAP_PREFIX}_$TIMESTAMP"

# --- EXECUTION PLAN ---
echo "====================================================================="
echo "EXECUTION PLAN:"
if [ "$ENABLE_DRY_RUN" = true ]; then
    echo "!!! DRY RUN MODE ACTIVE !!!"
fi

for PARENT_DATASET in "${!BACKUP_JOBS[@]}"; do
    echo "---------------------------------------------------------------------"
    echo "Job: Sync $PARENT_DATASET -> ${BACKUP_JOBS[$PARENT_DATASET]}"
    
    # Check for old snapshots to delete
    OLD_SNAPS=$(zfs list -H -t snapshot -o name -r "$PARENT_DATASET" 2>/dev/null | grep "@${SNAP_PREFIX}_")
    
    if [ -n "$OLD_SNAPS" ]; then
        echo "  [DELETE] The following old snapshots will be removed:"
        for s in $OLD_SNAPS; do
            echo "    - $s"
        done
    else
        echo "  [INFO] No old snapshots found to cleanup."
    fi

    # Check for new snapshot creation
    echo "  [CREATE] New recursive snapshot will be created:"
    echo "    - $PARENT_DATASET@$NEW_SNAP_NAME"
done
echo "====================================================================="
echo "Starting in 5 seconds..."
sleep 5
echo ""

# --- LOGIC ---
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#  WARNING: DO NOT EDIT THE LOGIC BELOW UNLESS YOU KNOW WHAT YOU ARE DOING
#  ESPECIALLY THE NESTED DATASET EXCLUSION LOGIC
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

for PARENT_DATASET in "${!BACKUP_JOBS[@]}"; do
    TARGET_BASE="${BACKUP_JOBS[$PARENT_DATASET]}"
    
    echo "====================================================================="
    echo "PARENT: $PARENT_DATASET"

    # 1. CLEANUP OLD SNAPSHOTS
    zfs list -H -t snapshot -o name -r "$PARENT_DATASET" | grep "@${SNAP_PREFIX}_" | xargs -n 1 zfs destroy 2>/dev/null

    # 2. CREATE NEW SNAPSHOTS
    if [ "$ENABLE_DRY_RUN" = false ]; then
        zfs snapshot -r "$PARENT_DATASET@$NEW_SNAP_NAME"
    fi

    # 3. PROCESS ALL DATASETS IN TREE
    ALL_DATASETS=$(zfs list -H -o name -r "$PARENT_DATASET")

    for DS in $ALL_DATASETS; do
        DS_MOUNT=$(zfs get -H -o value mountpoint "$DS")
        REL_PATH=${DS#$PARENT_DATASET}
        REL_PATH=${REL_PATH#/} 

        CURRENT_TARGET="$TARGET_BASE"
        [ -n "$REL_PATH" ] && CURRENT_TARGET="$TARGET_BASE/$REL_PATH"

        SNAP_SOURCE="$DS_MOUNT/.zfs/snapshot/$NEW_SNAP_NAME/"

        if [ "$DS" == "$PARENT_DATASET" ]; then
            echo "  [ROOT] Syncing Parent Dataset: $DS"
        else
            echo "  [CHILD] Transitioning to Nested Dataset: $DS"
        fi
        echo "     -> Target: $CURRENT_TARGET"
        
        if [ "$ENABLE_DRY_RUN" = false ]; then
            mkdir -p "$CURRENT_TARGET"
            
            # --- CRITICAL FIX FOR NESTED DATASETS ---
            # We search for IMMEDIATE children of this dataset.
            # We exclude these folders from the current rsync run.
            # This prevents rsync from deleting the content of child datasets in the target!
            
            EXCLUDE_ARGS=""
            CHILD_DATASETS=$(zfs list -H -o name -r -d 1 "$DS" | grep -v "^$DS$")
            for CHILD in $CHILD_DATASETS; do
                # Extract only the name of the child folder
                CHILD_NAME=${CHILD##*/}
                EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=/$CHILD_NAME"
                echo "     (Protecting child dataset folder: /$CHILD_NAME)"
            done

            # Execute rsync
            # -a: Archive, -v: Verbose, -i: Itemize, -c: Checksum
            # --delete: Delete extraneous files from dest dirs
            # -x: Don't cross filesystem boundaries
            # Pipe output to sed for human-readable logs
            eval rsync -avich --delete --inplace -x --ignore-times $EXCLUDE_ARGS "$SNAP_SOURCE" "$CURRENT_TARGET/" | \
            sed -E \
                -e 's/^>f\+\+\+\+\+\+\+\+ /\[NEW\] /' \
                -e 's/^>f\.st\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^>f\.s\.\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^>fc\.\.\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^>fc\.t\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^>fcst\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^>f\.\.t\.\.\.\.\.\. /\[MOD\] /' \
                -e 's/^\*deleting   /\[DEL\] /' \
                -e 's/^cd\+\+\+\+\+\+\+\+ /\[DIR\] /' \
                -e '/^\./d' 
        else
            echo "    [DRY] rsync -avich --delete -x \"$SNAP_SOURCE\" \"$CURRENT_TARGET/\""
        fi
    done

    # 4. FINAL CLEANUP
    [ "$ENABLE_DRY_RUN" = false ] && zfs destroy -r "$PARENT_DATASET@$NEW_SNAP_NAME"
done

echo "====================================================================="
echo "Done."