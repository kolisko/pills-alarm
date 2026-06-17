# Sdílený plán jen pro čtení

## Cíl
Člen skupiny chce číst sdílený plán a potvrzovat dávky, ale nemá měnit dávkování cizího plánu.

## Předpoklady
Uživatel je členem skupiny a plán vlastní někdo jiný.

## Scénář
1. Uživatel otevře `Plán`.
2. Aplikace zobrazí cizí sdílený plán s ikonou sdílení.
3. Uživatel otevře detail plánu.
4. Editor je jen pro čtení.
5. Uživatel otevře `Dnes`.
6. Pokud má ve skupině vyplněné jméno, může dávku potvrdit, přeskočit nebo vrátit stav.

## Očekávaný výsledek
Read-only omezení brání změně dávkování nebo odebrání plánu ze skupiny. Nebrání potvrzování, přeskakování ani vracení stavů dávky.

## Chybové stavy
- Pokud uživatel nemá vyplněné jméno, aplikace ukáže inline výzvu do `Skupina`.
- Pokud se práva změní, aplikace po reloadu zobrazí aktuální možnosti.
