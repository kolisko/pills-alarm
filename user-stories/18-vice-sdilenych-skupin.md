# Více sdílených skupin

## Cíl
Uživatel chce vidět plány sdílené v různých skupinách bez toho, aby se jejich dávky nebo historie pletly.

## Předpoklady
Uživatel je členem více skupin a v každé může být sdílen jiný plán.

## Scénář
1. Aplikace načte osobní úložiště.
2. Aplikace načte všechna dostupná skupinová úložiště.
3. Uživatel otevře `Plán`.
4. Aplikace zobrazí plány se zdrojem skupiny.
5. Uživatel otevře `Dnes`.
6. Dávky se stejným názvem a časem z různých skupin zůstávají oddělené.
7. Potvrzení se zapíše do správného skupinového úložiště.

## Očekávaný výsledek
Každý plán je soukromý nebo sdílený právě v jedné skupině. Různé skupiny se neslévají do jednoho potvrzení ani jedné historie.

## Chybové stavy
- Pokud jedna skupina nejde načíst, ostatní skupiny a osobní plány zůstanou viditelné.
- Pokud chce uživatel sdílet stejný plán do další skupiny, aplikace mu to v první verzi nedovolí.
