# Alarmy - zrušení po shared sync

## Cíl
Když člen skupiny potvrdí dávku, zařízení ostatních členů mají po synchronizaci zrušit staré alarmy.

## Předpoklady
Uživatel A a uživatel B jsou ve stejné sdílené skupině a oba mají naplánovaný alarm pro sdílenou dávku.

## Scénář
1. Uživatel A potvrdí sdílenou dávku.
2. Aplikace uživatele A uloží potvrzení do skupinové úložištěu vlastníka.
3. Aplikace uživatele A zruší svoje lokální alarmy pro tuto dávku.
4. Zařízení uživatele B dostane synchronizační příležitost.
5. Aplikace uživatele B načte skupinové úložiště.
6. Aplikace uživatele B zjistí, že dávka už je potvrzená členem skupiny.
7. Aplikace uživatele B označí dávku jako podanou.
8. Aplikace uživatele B zruší svoje lokální alarmy pro tuto dávku.
9. Uživatel B vidí, kdo dávku potvrdil.

## Očekávaný výsledek
Sdílené potvrzení zastaví alarmy všech členů skupiny, jakmile jejich zařízení provedou synchronizaci.

## Chybové stavy
- Pokud zařízení člena není online, může dočasně držet starý alarm.
- Pokud silent push nedorazí, stav opraví foreground reload, periodický reload nebo ruční refresh.
- Pokud potvrzení nejde načíst, aplikace zobrazí chybu synchronizace.
