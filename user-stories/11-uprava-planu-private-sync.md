# Úprava plánu - private sync

## Cíl
Uživatel chce upravit osobní plán na jednom zařízení a vidět změnu na ostatních svých zařízeních.

## Předpoklady
Zařízení A a zařízení B jsou přihlášená ke stejnému iCloud účtu a zobrazují stejný osobní plán.

## Scénář
1. Uživatel na zařízení A otevře osobní plán.
2. Uživatel změní čas nebo dávkování.
3. Aplikace na zařízení A uloží plán do osobního CloudKit prostoru.
4. Aplikace na zařízení A aktualizuje `Plán`, `Dnes` a alarmy.
5. Zařízení B dostane synchronizační příležitost.
6. Aplikace na zařízení B načte osobní CloudKit prostor.
7. Aplikace na zařízení B zobrazí upravený plán.
8. Aplikace na zařízení B přepočítá `Dnes`.
9. Aplikace na zařízení B zachová identitu upravených dávkovacích slotů a nepřepáruje stará potvrzení nebo přeskočení podle nového času.
10. Aplikace na zařízení B přeplánuje lokální alarmy podle upraveného plánu.
11. Uživatel na zařízení B vidí stejnou verzi plánu jako na zařízení A.

## Očekávaný výsledek
Osobní plán má po synchronizaci stejnou podobu na všech zařízeních stejného iCloud účtu.

## Chybové stavy
- Pokud zařízení B není online, změna se zobrazí až po dalším úspěšném reloadu.
- Pokud silent push nepřijde, změnu načte foreground reload, periodický reload nebo pull-to-refresh.
- Pokud zařízení B mělo naplánované alarmy podle starého času, po synchronizaci je přepočítá podle nového času.
- Pokud úprava na zařízení A smaže dávkovací slot, zařízení B po synchronizaci odstraní jeho budoucí dávky, alarmy a odpovídající běžnou historii.
