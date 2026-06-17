# Ruční refresh obrazovek

## Cíl
Uživatel chce ručně ověřit aktuální cloudový stav potažením dolů na obrazovkách, které zobrazují synchronizovaná data.

## Předpoklady
Aplikace je online a uživatel je na obrazovce `Dnes`, `Plán`, `Skupina`, `Historie` nebo `Alarmy`.

## Scénář
1. Uživatel potáhne obrazovku dolů.
2. Aplikace spustí reload z CloudKitu.
3. Aplikace zobrazí jednotný jemný indikátor synchronizace.
4. Aplikace načte osobní i sdílené CloudKit prostory.
5. Aplikace aktualizuje data na aktuální obrazovce.
6. Aplikace přepočítá lokální alarmy, pokud se změnily plány nebo potvrzení.
7. Uživatel vidí aktuální stav bez restartu aplikace.

## Očekávaný výsledek
Pull-to-refresh je jednotný způsob, jak si uživatel může vynutit synchronizaci a ověřit aktuální stav.

## Chybové stavy
- Pokud reload selže, aplikace zobrazí centrální chybu.
- Pokud je zařízení offline, aplikace nechá poslední známý stav pro čtení a ukáže chybu připojení.
- Dokud není připojení obnovené a reload úspěšný, aplikace zakáže potvrzení, přeskočení, vrácení, úpravy plánů a změny sdílení.
- Pokud reload doběhne bez změn, UI zůstane stabilní a neposkočí.
