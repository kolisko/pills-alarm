# Smazání plánu - private sync

## Cíl
Uživatel chce smazat osobní plán na jednom zařízení a mít ho odstraněný i na ostatních svých zařízeních.

## Předpoklady
Zařízení A a zařízení B jsou přihlášená ke stejnému iCloud účtu a zobrazují stejný osobní plán.

## Scénář
1. Uživatel smaže plán na zařízení A.
2. Aplikace na zařízení A smaže plán z osobního CloudKit prostoru.
3. Aplikace na zařízení A odstraní plán z UI, odstraní potvrzení a přeskočení tohoto plánu z běžné `Historie` a přeplánuje alarmy.
4. Zařízení B dostane synchronizační příležitost.
5. Aplikace na zařízení B načte osobní CloudKit prostor.
6. Aplikace na zařízení B zjistí, že plán už neexistuje.
7. Aplikace na zařízení B odstraní plán z `Plán`.
8. Aplikace na zařízení B odstraní dávky z `Dnes`.
9. Aplikace na zařízení B odstraní potvrzení a přeskočení tohoto plánu z běžné `Historie`.
10. Aplikace na zařízení B přeplánuje lokální alarmy.

## Očekávaný výsledek
Smazání osobního plánu je po synchronizaci vidět na všech zařízeních stejného iCloud účtu a odstraní i jeho běžnou historii.

## Chybové stavy
- Pokud zařízení B není online, plán může dočasně zobrazovat starý stav.
- Po dalším úspěšném reloadu musí plán zmizet.
- Pokud smazání na zařízení A selže, zařízení B se nesmí změnit.
