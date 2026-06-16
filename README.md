# Pill Care

SwiftUI iOS aplikace pro realne sdilene potvrzovani podani leku pres iCloud / CloudKit.

## Soucasny stav

- data nejsou fake ani lokalni zdroj pravdy
- skupina pece se zaklada jako CloudKit zaznam v iCloud private database
- pozvani dalsich lidi probiha pres systemovy `UICloudSharingController`
- potvrzeni davky se uklada jako CloudKit record a siri se pres iCloud share
- aplikace prijima CloudKit share metadata pres `UIApplicationDelegate`
- CloudKit silent push notifikace vyvolaji reload sdileneho stavu
- pokud CloudKit neni dostupny, aplikace ukaze chybu misto lokalniho fallbacku

## Nutne Apple nastaveni

V Apple Developer portalu a Xcode musi existovat iCloud container:

`iCloud.com.kolisko.pillcare`

Target musi mit capabilities:

- iCloud / CloudKit
- Push Notifications
- Background Modes / Remote notifications

Entitlements jsou v `PillsAlarm/PillsAlarm.entitlements`.
