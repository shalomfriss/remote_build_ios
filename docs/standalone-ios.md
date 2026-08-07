# Standalone iPhone installation

The iPhone app does not need Xcode, a USB cable, or a local Wi-Fi network after it is installed. The recommended installation path is TestFlight. The Mac still runs the companion and coding agent, because the iPhone is the remote client rather than the agent host.

## First-time setup

1. Join the Apple Developer Program and sign in to your Apple account in Xcode.
2. Create an App Store Connect app record whose bundle ID is `app.grokbuild.ios`.
3. From the repository root, archive and upload a signed build:

   ```bash
   APPLE_TEAM_ID=8NN27Z7TQR ./ios/GrokApp/scripts/distribute-standalone.sh --upload
   ```

4. In App Store Connect, open the app's TestFlight tab and add the processed build to an internal or external testing group.
5. Install TestFlight on the iPhone, accept the invitation, and install the app.

The TestFlight-installed app launches and connects without Xcode attached. TestFlight builds are available for 90 days, so upload a newer build before the current one expires.

## Connect away from the Mac's network

Start the companion with a public HTTPS/WebSocket tunnel:

```bash
./companion/scripts/agent-phone --ngrok
```

Enter the printed `wss://...ngrok-free.app/acp` endpoint and PIN in the iPhone app. Do not use the Mac's `192.168...` address over cellular; that address is reachable only from the local network. Keep the Mac, companion process, and ngrok tunnel running while using the app.

## Registered-device export

For a device registered to the Apple Developer team, export a signed package instead of uploading to TestFlight:

```bash
APPLE_TEAM_ID=8NN27Z7TQR ./ios/GrokApp/scripts/distribute-standalone.sh --method release-testing
```

The exported `.ipa` is written under `build/ios-distribution`. Registered-device packages require device registration and Developer Mode, so TestFlight is usually simpler for a standalone phone.

## Configuration

- `APPLE_TEAM_ID` or `--team-id`: signing team
- `IOS_BUILD_NUMBER` or `--build-number`: unique upload build number
- `IOS_DISTRIBUTION_DIR` or `--output-dir`: archive and export location

Signing certificates and Apple credentials remain in Xcode's account/keychain storage and are not written to this repository.
