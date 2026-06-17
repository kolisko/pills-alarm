# Alarmy - zrušení po private sync

## Cíl
Když uživatel potvrdí dávku na jednom svém zařízení, ostatní jeho zařízení mají po synchronizaci zrušit staré alarmy.

## Předpoklady
Zařízení A a zařízení B patří stejnému iCloud účtu a obě mají naplánovaný alarm pro stejnou dávku.

## Scénář
1. Na zařízení B je naplánovaný budoucí alarm pro dávku.
2. Uživatel na zařízení A potvrdí dávku.
3. Aplikace na zařízení A uloží potvrzení do osobního CloudKit prostoru.
4. Zařízení B dostane synchronizační příležitost.
5. Aplikace na zařízení B načte CloudKit stav.
6. Aplikace na zařízení B zjistí, že dávka už je potvrzená.
7. Aplikace na zařízení B zruší lokální alarmy pro tuto dávku.
8. Uživatel na zařízení B už pro potvrzenou dávku neslyší alarm.

## Očekávaný výsledek
Po private synchronizaci žádné zařízení stejného uživatele nehouká kvůli dávce, která už byla potvrzená.

## Chybové stavy
- Pokud zařízení B synchronizaci nestihne, může alarm dočasně zaznít.
- Po nejbližší úspěšné synchronizaci musí být alarm odstraněn.
- Pokud se reload nepovede, audit ukáže starý čas posledního přeplánování nebo chybu.
