# Files / iCloud folder backup testing

This branch restores the earlier user-selected Files folder flow. iCloud Drive is a destination chosen in Files; successful cloud writes still require device validation.

1. Open Apollo Reborn → Data → Automatic Backups.
2. Enable Automatic Backups, then select Every Minute (Testing).
3. Set up a folder in iCloud Drive and confirm Files returns a usable folder.
4. Keep Apollo open. Verify the first archive is written and Next Backup is approximately one minute after Last Backup.
5. Wait for another scheduled run. Verify a second archive appears and the next run advances another minute.
6. Relaunch Apollo. Confirm Every Minute (Testing) persists and the saved folder reconnects.
7. Switch to Every Day, Every 3 Days, and Every 7 Days; confirm the schedule changes accordingly.
8. Disable Automatic Backups; confirm scheduled writes stop. Manual Back Up Now should still work.
9. Disconnect the selected provider and confirm the UI reports the folder error. Reconnect it and retry. Failed automatic attempts retain the existing 15-minute retry backoff.
10. Restore a backup through Files and verify the current upstream archive/keychain validation is preserved.

The minute option stores 0 in AutomaticBackupIntervalDays and maps that value to 60 seconds. The default remains three days. Scheduling runs while Apollo is active or when it next becomes active; it does not request a background execution entitlement.
