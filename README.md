# ZFS to Rsync Backup Script

A backup solution to sync **ZFS snapshots** to a local or remote target directory using `rsync`, designed to handle nested ZFS datasets automatically without data loss and unnecessary retransmissions.

## Features

- **3-2-1 Backup Strategy Ready**: Serves as an excellent bridge to move ZFS data to a non-ZFS storage (e.g., specific disks, unassigned devices, or remote servers) for your second or third backup copy.
- **Automated Snaps & Cleanups**: Automatically creates temporary ZFS snapshots for consistent backups and cleans them up afterwards.
- **Delta Headers Only**: Uses ZFS snapshots to ensure only consistent file states are backed up.
- **Nested Dataset Protection**: **(Critical Feature)** Specifically handles ZFS parents with nested children. It excludes child dataset paths during the parent's sync to prevent `rsync --delete` from accidentally wiping the child dataset's content in the backup target. Each child dataset is then backed up in its own iteration.
- **Human-Readable Logging**: Translates cryptic rsync codes (e.g., `>fc.t...`) into readable statuses like `[NEW]`, `[MOD]`, and `[DEL]`.
- **Dry Run Mode**: Simulate the process to check paths and excludes without moving any data.

---

## Usage

### 1. Configuration

Open `skript.sh` and edit the `BACKUP_JOBS` array.
The key is the **ZFS source dataset**, and the value is the **destination path**.

```bash
declare -A BACKUP_JOBS
BACKUP_JOBS=(
    ["pool/dataset"]="/mnt/backup/destination"
    ["pool/docker"]="/mnt/backup/docker_backup"
)
```

### 2. Run

Execute the script as root (or a user with ZFS/rsync permissions):

```bash
sudo ./skript.sh
```

---

## How It Works (The Logic)

1.  **Cleanup**: Removes any stray left-over temporary snapshots from stalled previous runs.
2.  **Snapshot**: Takes a recursive snapshot (`@rsync_auto_TIMESTAMP`) of the parent dataset.
3.  **Iteration**: Loops through **every** dataset (parent and children).
4.  **The "Nested" Fix**:
    - When syncing a parent dataset (e.g., `pool/data`), the script detects immediate child datasets (e.g., `pool/data/child`).
    - It explicitly adds `--exclude=/child` to the `rsync` command for the parent.
    - **Why?** Standard `rsync -ax --delete` would see the empty mountpoint of the child dataset in the snapshot and delete the _actual_ backed-up content of the child in the destination.
    - The child dataset (`pool/data/child`) is then processed in its own loop iteration, ensuring its data is synced correctly to `.../destination/child`.
5.  **Sync**: Runs `rsync` with checksums and deletion enabled to make the target an exact clone of the snapshot, without retransmitting every file.
6.  **Cleanup**: Destroys the temporary snapshot.

---

## Logging Output

The script formats rsync output for easier reading:

| Tag     | Meaning                                         |
| :------ | :---------------------------------------------- |
| `[NEW]` | New file created                                |
| `[MOD]` | File modified (content or metadata)             |
| `[DEL]` | File deleted at destination (was not in source) |
| `[DIR]` | Directory created                               |

---

## Important Notes

- **Do not edit the logic section**: especially the exclude loop, unless you fully understand the ZFS/rsync interaction.
- **Dry Run**: Set `ENABLE_DRY_RUN=true` to test. **Note:** In Dry Run, snapshots are _not_ created. The script generates the command it _would_ run. Since the source snapshot path won't exist, you cannot copy paste the command to run it manually without creating a snapshot first.
- **TEST FIRST**: Always test the script in a non-critical environment before using it in production. I am not responsible for any data loss or damage caused by this script.
