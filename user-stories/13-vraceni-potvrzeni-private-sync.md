# Vrácení potvrzení - private sync

## Cíl
Uživatel chce vrátit potvrzení na jednom svém zařízení a vidět opravu na ostatních svých zařízeních.

## Předpoklady
Zařízení A a zařízení B jsou přihlášená ke stejnému iCloud účtu a obě vidí dávku jako podanou nebo přeskočenou.

## Scénář
1. Uživatel na zařízení A klepne u dávky na `Zpět`.
2. Aplikace na zařízení A smaže cloudový stav `Podáno` nebo `Přeskočeno` pro stabilní identitu dávky z osobního CloudKit prostoru.
3. Aplikace na zařízení A zobrazí dávku jako nepodanou.
4. Aplikace na zařízení A přeplánuje lokální alarmy.
5. Zařízení B dostane synchronizační příležitost.
6. Aplikace na zařízení B načte osobní CloudKit prostor.
7. Aplikace na zařízení B zjistí podle stabilní identity dávky, že cloudový stav už neexistuje.
8. Aplikace na zařízení B zobrazí dávku jako nepodanou.
9. Aplikace na zařízení B přeplánuje lokální alarmy.

## Očekávaný výsledek
Oprava potvrzení se po synchronizaci projeví na všech zařízeních stejného uživatele.

## Chybové stavy
- Pokud zařízení B není online, uvidí starý stav až do dalšího reloadu.
- Pokud smazání z CloudKitu selže, stav se nesmí lokálně tvářit jako úspěšně vrácený.
- Pokud jiné zařízení mezitím úspěšně zapsalo pro stejnou dávku nový stav, první úspěšný cloudový stav po vrácení vyhrává podle pravidel v `00-pravidla-a-slovnik.md`.
- Pokud dávka už nemá být alarmována, aplikace ji neplánuje znovu jen kvůli vrácení.
