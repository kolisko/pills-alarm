# Potvrzení dávky - private sync

## Cíl
Uživatel chce potvrdit dávku na jednom svém zařízení a vidět potvrzení na všech svých zařízeních.

## Předpoklady
Zařízení A a zařízení B jsou přihlášená ke stejnému iCloud účtu a zobrazují stejný osobní plán.

## Scénář
1. Uživatel na zařízení A otevře `Dnes`.
2. Uživatel klepne na `Podat`.
3. Aplikace na zařízení A zapíše potvrzení pro stabilní identitu dávky do osobního CloudKit prostoru.
4. Aplikace na zařízení A označí dávku jako podanou a přeplánuje alarmy.
5. Zařízení B dostane synchronizační příležitost přes push, foreground, periodický reload nebo ruční refresh.
6. Aplikace na zařízení B načte osobní CloudKit prostor.
7. Aplikace na zařízení B najde potvrzení stejné dávky podle její stabilní identity.
8. Aplikace na zařízení B označí dávku jako podanou a zruší zastaralé alarmy.
9. Uživatel na zařízení B vidí stav `Podáno`.

## Očekávaný výsledek
Potvrzení dávky je pro stejný iCloud účet jedno společné cloudové rozhodnutí, ne lokální stav jednotlivého zařízení.

## Chybové stavy
- Pokud zařízení B nestihne synchronizaci před naplánovaným alarmem, může dočasně použít starý lokální alarm.
- Po nejbližší úspěšné synchronizaci musí zařízení B alarm odstranit.
- Pokud jiné zařízení mezitím úspěšně zapsalo pro stejnou dávku jiný stav, první úspěšný cloudový stav vyhrává a pozdější protichůdná akce se po reloadu nahradí aktuálním stavem z CloudKitu.
