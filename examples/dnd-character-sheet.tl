{NAME="Kaelen Stormward"}
{CLASS="Cleric 5 (War Domain)"}
{LEVEL=5}
{PROF=2+floor((LEVEL-1)/4)}

{STR=14}{DEX=12}{CON=13}{INT=10}{WIS=16}{CHA=8}
{STRM=floor((STR-10)/2)}{DEXM=floor((DEX-10)/2)}{CONM=floor((CON-10)/2)}
{INTM=floor((INT-10)/2)}{WISM=floor((WIS-10)/2)}{CHAM=floor((CHA-10)/2)}

{HP=38}{HPM=38}
{AC=17}{INIT=DEXM}{GOLD=245}
{SPELLMOD=WISM}{SAVEDC=8+PROF+SPELLMOD}

{SAVE_TRAINING="saving throw training: 0 = none, 1 = proficient, 2 = expertise"}
{STRP=1}{DEXP=0}{CONP=1}{INTP=0}{WISP=1}{CHAP=0}
{STRB=STRM+STRP*PROF}{DEXB=DEXM+DEXP*PROF}{CONB=CONM+CONP*PROF}
{INTB=INTM+INTP*PROF}{WISB=WISM+WISP*PROF}{CHAB=CHAM+CHAP*PROF}

{NAME} | {CLASS}

HP {HP}/{HPM} | Gold {GOLD} gp
> AC {AC} | Initiative {INIT} | Save DC {SAVEDC}

Abilities
> ---------
> @grid [
Ability | Score | Mod | Save | Prof
> STR | {STR} | {STRM} | {STRB} | {ifelse(STRP==2, "E", ifelse(STRP==1, "P", "-"))}
> DEX | {DEX} | {DEXM} | {DEXB} | {ifelse(DEXP==2, "E", ifelse(DEXP==1, "P", "-"))}
> CON | {CON} | {CONM} | {CONB} | {ifelse(CONP==2, "E", ifelse(CONP==1, "P", "-"))}
> INT | {INT} | {INTM} | {INTB} | {ifelse(INTP==2, "E", ifelse(INTP==1, "P", "-"))}
> WIS | {WIS} | {WISM} | {WISB} | {ifelse(WISP==2, "E", ifelse(WISP==1, "P", "-"))}
> CHA | {CHA} | {CHAM} | {CHAB} | {ifelse(CHAP==2, "E", ifelse(CHAP==1, "P", "-"))}
]
> P = proficient, E = expertise, - = untrained

Inventory
> ---------
> Backpack | 5 lb
> Bedroll | 7 lb
> Rations, 10 days | 20 lb
> Rope, hempen 50 ft | 10 lb
> Holy water (2 vials) | 2 lb
> Potion of Healing | 0.5 lb

Weapons
> -------
> Mace | 1d6+{STRM} bludgeoning | 1h | 4 lb
> Warhammer | 1d8+{STRM} bludgeoning | 1h | 2 lb
> Light crossbow | 1d8+{DEXM} piercing | 2h | 5 lb

Spells
> ------
> Save DC {SAVEDC} | Spell attack +{PROF+SPELLMOD}

Cantrips | Sacred Flame, Guidance, Light
> 1st (4) | Bless, Cure Wounds, Shield of Faith
> 2nd (3) | Spiritual Weapon, Hold Person, Aid
> 3rd (2) | Spirit Guardians, Revivify

Notes
> -----
> Kaelen is a war cleric of the Stormlord.
> He tallies every monster he has slain.
> He will not heal anyone who insults the sea.

> Ideal | "The storm does not negotiate."
> Bond | "My ship needs a captain."
> Flaw | "I answer every slight."
