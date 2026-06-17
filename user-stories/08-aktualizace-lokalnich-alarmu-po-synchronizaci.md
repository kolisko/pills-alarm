# Aktualizace lokálních alarmů po synchronizaci

## Cíl
Uživatel chce, aby zařízení po každé synchronizaci zrušilo alarmy, které už podle CloudKitu nemají houkat, a naplánovalo alarmy, které podle aktuálních dat houkat mají.

## Předpoklady
Zařízení má lokálně naplánované alarmy a v CloudKitu se mezitím mohl změnit plán nebo stav dávky.

## Scénář
1. Zařízení má lokálně naplánovaný alarm pro budoucí dávku.
2. Na jiném zařízení stejného uživatele nebo u jiného člena skupiny se změní cloudový stav.
3. Změna může být potvrzení dávky, přeskočení dávky, vrácení potvrzení, úprava času dávkovacího slotu, úprava množství, smazání slotu nebo smazání plánu.
4. Aplikace na tomto zařízení dostane synchronizační příležitost přes push, návrat do popředí, periodický reload nebo ruční refresh.
5. Aplikace načte aktuální osobní a sdílená data z CloudKitu.
6. Aplikace porovná aktuální dávky a potvrzení podle stabilní identity dávkovacích slotů s lokálně naplánovanými alarmy.
7. Aplikace zruší alarmy pro dávky, které už jsou podané, přeskočené, smazané nebo mají po úpravě slotu jiný čas.
8. Aplikace naplánuje nové alarmy pro dávky, které podle aktuálního CloudKit stavu ještě mají upozorňovat.
9. Uživatel v `Nastavení` > `Alarmy` vidí aktuální počet čekajících alarmů a čas posledního přeplánování.

## Očekávaný výsledek
Lokální alarmy jsou po synchronizaci vždy odvozené z aktuálního CloudKit stavu a stabilních identit dávkovacích slotů. Staré alarmy nezůstávají naplánované jen proto, že byly vytvořené před změnou na jiném zařízení.

## Chybové stavy
- Pokud zařízení není online, alarmy se aktualizují až po dalším úspěšném reloadu.
- Pokud aktualizace alarmů selže, aplikace zobrazí chybu v auditu alarmů.
- Pokud silent push nedorazí, aktualizaci zajistí návrat aplikace do popředí, periodický reload nebo ruční refresh.
