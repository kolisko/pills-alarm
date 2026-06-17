# Debug diagnostika jen v simulátoru

## Cíl
Vývojář chce spouštět reálnou CloudKit diagnostiku v debug simulátoru, ale uživatel v TestFlightu nebo produkci ji nesmí vidět.

## Předpoklady
Aplikace se spouští buď jako debug build v simulátoru, nebo jako TestFlight/Release build.

## Scénář
1. Vývojář spustí debug build v simulátoru.
2. Aplikace zobrazí v `Skupina` sekci `Debug CloudKit`.
3. Vývojář spustí reálný CloudKit test.
4. Aplikace zobrazí průběh a výsledek diagnostiky.
5. Vývojář spustí TestFlight nebo Release build.
6. Aplikace nezobrazí sekci `Debug CloudKit`.
7. Uživatel v TestFlightu nevidí žádné diagnostické tlačítko ani technické testovací logy.

## Očekávaný výsledek
Diagnostika je dostupná pouze pro vývoj v simulátoru a nedostane se do TestFlight/Release uživatelského rozhraní.

## Chybové stavy
- Pokud diagnostika selže v simulátoru, zobrazí detail chyby pro vývojáře.
- Pokud se diagnostická sekce objeví v TestFlightu, je to release blocker.
- Pokud diagnostika po sobě vytvoří testovací data, musí je po skončení odstranit.
