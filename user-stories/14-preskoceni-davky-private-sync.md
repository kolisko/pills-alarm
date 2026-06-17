# Přeskočení dávky - private sync

## Cíl
Uživatel chce přeskočit dávku na jednom svém zařízení a vidět přeskočení na ostatních svých zařízeních.

## Předpoklady
Zařízení A a zařízení B jsou přihlášená ke stejnému iCloud účtu a vidí stejnou nepodanou dávku.

## Scénář
1. Uživatel na zařízení A klepne na `Přeskočit`.
2. Aplikace na zařízení A zobrazí potvrzovací dialog.
3. Uživatel přeskočení potvrdí.
4. Aplikace na zařízení A zapíše stav `Přeskočeno` pro stabilní identitu dávky do osobního CloudKit prostoru.
5. Aplikace na zařízení A přeplánuje alarmy.
6. Zařízení B dostane synchronizační příležitost.
7. Aplikace na zařízení B načte osobní CloudKit prostor.
8. Aplikace na zařízení B zobrazí dávku jako přeskočenou.
9. Aplikace na zařízení B zruší zastaralé alarmy pro tuto dávku.

## Očekávaný výsledek
Přeskočení osobní dávky je po synchronizaci společné pro všechna zařízení stejného iCloud účtu.

## Chybové stavy
- Pokud zařízení B není online, může dočasně zobrazovat starý stav.
- Pokud zápis na zařízení A selže, zařízení B se nesmí změnit.
- Pokud zařízení B nebo jiné zařízení mezitím úspěšně zapsalo pro stejnou dávku jiný stav, první úspěšný cloudový stav vyhrává.
- Pokud silent push nedorazí, stav opraví foreground reload, periodický reload nebo ruční refresh.
