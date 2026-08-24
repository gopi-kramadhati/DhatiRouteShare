# Release notes

## 1.0.1 (versionCode 6)

Play Console "What's new" (keep under 500 characters):

```
• Import routes shared by friends — just tap the shared file to open it in RouteShare.
• More reliable background tracking and status notifications.
• Cleaner app icon.
• Bug fixes and stability improvements.
```

Under the hood (not shown to users):
- receive_sharing_intent + application/json intent filters for tap-to-import.
- Sanity-check + confirmation dialog before importing a shared route.
- Runtime notification permission (Android 13+).
- Cleanup of any orphaned foreground service on launch.
- Full-square launcher icon (no black corners).
- Route files remain .json (custom extensions break tap-to-open via messengers).
