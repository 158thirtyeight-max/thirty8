# 01 — Reference Identity & Input Validation

## Verified inputs

### Customer reference
- Supplied file: `redBus+Book+Bus,+Train+Tickets_82.5.5_APKPure.xapk`
- SHA-256: `7edb7442213570757d7c2164acd7755f9587f3b5cdd1115c2d2194c7341ab019`
- XAPK package name: `in.redbus.android`
- App name: `redBus`
- Version: `82.5.5`
- Version code: `825050`
- minSdk: `26`
- targetSdk: `35`
- Base APK inside XAPK: `in.redbus.android.apk`
- Split APKs: `activities`, `config.arm64_v8a`, `config.xxhdpi`, `ferry`, `gamification`, `redTv`, `waterways`

### Operator reference
- Supplied file: `redBus+Plus-+For+Bus+Operators_2.0.6_APKPure.apk`
- SHA-256: `62ae4197f1d25db942b084bc5135293084b4e383b92f5ed314f58694e738bf4b`
- Package: `redbus.rbplus.android`
- Version: `2.0.6`
- Version code: `39`
- Launcher: `redbus.rbplus.android.ui.activity.Splash`
- Application class: `redbus.rbplus.android.SSApplication`

## Previously supplied invalid file

The earlier file named `redbus.apk` was validated as an Aptoide package (`cm.aptoide.pt`) and must remain archived only as an invalid reference. Never infer redBus customer behavior from it.

## Input validation gate for every future APK

Before using any APK as evidence, the agent must record:

- filename
- SHA-256
- package/application ID
- app label
- version name/code
- minSdk/targetSdk
- launcher activity
- application class
- split relationships
- signing certificate fingerprint if obtainable
- size
- tool used
- evidence confidence

If claimed identity and actual package identity disagree, mark `INVALID_REFERENCE` and stop deriving product behavior from that file.

## Why XAPK matters

The customer XAPK is not one APK. It is a base APK plus feature/configuration splits. Static analysis should therefore inspect the **base and relevant split APKs**, not only the container filename.
