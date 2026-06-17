# Sdílená skupina na více zařízeních pozvaného

## Cíl
Pozvaný uživatel chce po přijetí skupiny na jednom zařízení vidět stejnou skupinu a její sdílené plány i na dalších zařízeních stejného iCloud účtu.

## Předpoklady
Uživatel B má zařízení B1 a B2 přihlášená ke stejnému iCloud účtu a přijme pozvánku na B1.

## Scénář
1. Uživatel B přijme iCloud pozvánku na B1.
2. Aplikace B1 načte skupinové úložiště.
3. Uživatel B vyplní svoje jméno.
4. Uživatel B otevře aplikaci na B2.
5. Aplikace B2 načte osobní i dostupná skupinová úložiště.
6. Uživatel B vidí stejnou skupinu, členy a plány výslovně přidané do skupiny.

## Očekávaný výsledek
Skupina přijatá jedním zařízením je dostupná i na dalších zařízeních pozvaného uživatele, ale neobsahuje žádné nesdílené soukromé plány vlastníků.

## Chybové stavy
- Pokud zařízení B2 není online, skupina se načte později.
- Pokud profil uživatele B nejde načíst, sdílené potvrzování zůstane zamčené do doplnění jména.
