Place native bundle resources here. An AppIcon.icns is used as the application icon automatically.
Configure native permissions and URL schemes in ../Info.plist, and signing entitlements in ../Entitlements.plist.
Optional Swift files in ../Sources compile into PlatformSupport; import that module conditionally from AppContent when needed.
