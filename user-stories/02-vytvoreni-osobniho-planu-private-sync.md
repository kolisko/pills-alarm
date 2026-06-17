# Vytvoření osobního plánu - private sync

## Cíl
Uživatel chce vytvořit plán na jednom zařízení a vidět ho i na svých ostatních zařízeních se stejným iCloud účtem.

## Předpoklady
Uživatel má zařízení A a zařízení B přihlášené ke stejnému iCloud účtu.

## Scénář
1. Uživatel otevře `Plán` na zařízení A.
2. Aplikace na zařízení A načte osobní CloudKit úložiště.
3. Uživatel vytvoří a uloží nový osobní plán.
4. Aplikace na zařízení A uloží plán do osobního CloudKit úložiště.
5. Systém nebo aplikace na zařízení B spustí synchronizaci přes push, návrat do popředí, periodický reload nebo ruční stažení.
6. Aplikace na zařízení B načte osobní CloudKit úložiště stejného iCloud účtu.
7. Uživatel na zařízení B vidí nový plán v `Plán`.
8. Aplikace na zařízení B zobrazí odpovídající dávky v `Dnes` a přeplánuje lokální alarmy.

## Očekávaný výsledek
Obě zařízení čtou stejné osobní CloudKit úložiště a po synchronizaci zobrazují stejný plán.

## Chybové stavy
- Pokud zařízení B není online, plán se zobrazí až po obnovení připojení.
- Pokud silent push nepřijde, synchronizaci zajistí návrat do popředí, ruční obnovení nebo periodický reload.
- Pokud reload selže, zařízení B nesmí vytvořit duplicitní osobní úložiště.
