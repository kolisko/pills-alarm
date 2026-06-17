# Přeskočení dávky - jedno zařízení

## Cíl
Uživatel chce bezpečně označit dávku jako přeskočenou na zařízení, které právě používá.

## Předpoklady
V `Dnes` existuje nepodaná dávka a iCloud je dostupný.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync` nebo `shared sync` podle prostoru, ze kterého dávka pochází.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí nepodanou dávku.
3. Uživatel klepne na `Přeskočit`.
4. Aplikace zobrazí potvrzovací dialog.
5. Uživatel potvrdí přeskočení.
6. Aplikace zapíše stav `Přeskočeno` pro stabilní identitu této dávky do CloudKitu.
7. Aplikace zobrazí dávku jako přeskočenou.
8. Aplikace po přepočtu zobrazí přeskočení v `Historie` jako stav odvozený z CloudKitu.
9. Aplikace přeplánuje lokální alarmy.

## Očekávaný výsledek
Přeskočená dávka odpovídá cloudovému stavu a na tomto zařízení už pro ni neběží další alarmy.

## Chybové stavy
- Pokud uživatel dialog zruší, dávka zůstane nepodaná.
- Pokud zápis selže, dávka zůstane nepodaná.
- Pokud stejná dávka už má v CloudKitu stav `Podáno` nebo `Přeskočeno`, aplikace nevytvoří protichůdný stav a po reloadu zobrazí existující cloudový stav.
- Pokud dávka pochází ze sdíleného prostoru a uživatel nemá vyplněné jméno, aplikace uživatele navede do `Skupina`.
