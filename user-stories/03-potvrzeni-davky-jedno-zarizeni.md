# Potvrzení dávky - jedno zařízení

## Cíl
Uživatel chce rychle označit dávku jako podanou na zařízení, které právě používá.

## Předpoklady
V `Dnes` existuje nepodaná dávka a iCloud je dostupný.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync` nebo `shared sync` podle prostoru, ze kterého dávka pochází.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí dávky pro vybraný den.
3. Uživatel klepne na `Podat`.
4. Aplikace zapíše potvrzení pro stabilní identitu této dávky do CloudKit prostoru, ze kterého dávka pochází.
5. Aplikace po úspěšném zápisu označí dávku jako podanou.
6. Aplikace po přepočtu zobrazí potvrzení v `Historie` jako stav odvozený z CloudKitu.
7. Aplikace zruší nebo přeplánuje lokální alarmy pro potvrzenou dávku.
8. Uživatel vidí u dávky stav `Podáno`.

## Očekávaný výsledek
Lokální UI odpovídá potvrzení uloženému v CloudKitu a potvrzená dávka už na tomto zařízení znovu nehouká.

## Chybové stavy
- Pokud zápis selže, dávka zůstane nepodaná.
- Pokud uživatel klepne na podanou dávku, stav se nesmí resetovat.
- Pokud stejná dávka už má v CloudKitu stav `Podáno` nebo `Přeskočeno`, aplikace nevytvoří protichůdný stav a po reloadu zobrazí existující cloudový stav.
- Pokud dávka pochází ze sdíleného prostoru a uživatel nemá vyplněné jméno, aplikace ho navede do `Skupina`.
